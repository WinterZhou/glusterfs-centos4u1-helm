#!/bin/sh

# glusterfs的0号有状态节点
# 0号是一个主控节点，它负责新节点的add peer等工作
# 它在启动后，同POD内的另一个容器shadowadmin-0会感知到(@see ShadowStatefulSet.yaml)
# shadowadmin-0会做一些初始化操作，然后把控制权交给glusterfs-0

echo "当前POD：$POD_NAME "

# 限制启动数量
podnumber=${POD_NAME:0-1}
replicacount=${POD_COUNT}
if [[ "`expr $podnumber + 1`" -gt "$replicacount" ]]; then
   echo "当前POD超出主备数量设置：$replicacount, 不能启动"
   exit 1
fi


mkdir -p /glustervolumes
echo "创建/glustervolumes目录"


############################ 启动glusterfs#################################
# @see https://github.com/gluster/gluster-kubernetes/issues/298
echo "启动systemd"
nohup /usr/lib/systemd/systemd --system 2>&1 &


############################ 启动控制脚本 ############################
echo "启动控制脚本....."
# 这是一个控制脚本
# 每一段时间，检查一下是否有新的节点加入，如果有，就add peer，并且设置brick
# 如果3次检查不正确，则删除这个peer
# TODO: 支持“rancher更新”，也就是可以新增和删除卷

WAIT=3

RETRY_TIMES=0

while [[ ${RETRY_TIMES} -lt 60 ]]; do
    ((RETRY_TIMES++))
    echo -n "判断glusterfs进程 $RETRY_TIMES times"
    echo ".............................." && sleep ${WAIT}

    content=$(ps aux | grep /usr/sbin/glusterd|grep -v grep | awk '{print $2}')
    if [[ "$content" -ge 0  ]]; then
        echo "glusterfs已经启动"
        break
    fi

    echo "重试判断glusterfs进程"
done

if [[ "$RETRY_TIMES" -ge 60 ]]; then
    echo "判断glusterfs进程超时。无法获取到glusterd进程id"
    exit 0
fi

#------ 0号节点，等待shadowadmin初始化集群完成
podnumber=${POD_NAME:0-1}
if [[ "${podnumber}" -eq 0 ]]; then
    echo "开启控制脚本...."
    # ！！当前版本为比较happy的，没有考虑到节点的变更，也就是说只考虑了增加
    # 如果当前gluster-0被加入了节点，则说明shadowadmin已经初始化完成
    echo "判断shadowadmin初始化情况 .........."
    RETRY_TIMES=0
    while [[ ${RETRY_TIMES} -lt 60 ]]; do
        rslt=$(gluster peer status)
        echo ${rslt}
        rlst=$(gluster peer status|grep Peers|awk '{print $4}')
        if [[ "$rlst" -gt 0  ]]; then
            echo "shadowadmin已经初始化，并且将glusterfs-0加入集群"
            break
        fi

        echo "重试判断shadowadmin初始化情况 .........." && sleep ${WAIT}
    done

    if [[ "$RETRY_TIMES" -ge 60 ]]; then
        echo "判断shadowadmin初始化情况超时。没有被shadowadmin加入集群"
        exit 0
    fi
fi

echo "挂载系统卷...."
#------ 每一个节点，都通过0号节点挂载内部系统卷，并且写入一个标志文件。内部系统卷在shadowadmin中创建
mkdir -p /vol_system
RETRY_TIMES=0
OK="false"
while [[ ${RETRY_TIMES} -lt 60 ]]; do
    array=(${GLUSTERFS_NODES//,/ })
    for var in ${array[@]}
    do
        echo "mount -t glusterfs ${var}:vol_system /vol_system"
        rslt=$(mount -t glusterfs ${var}:vol_system /vol_system 2>&1)
        echo "挂载系统卷结果: ${rslt}"
        rslt=$(echo ${rslt} |grep "failed\|ERROR:"|wc -c)
        echo ${rslt}
        if [[ ${rslt} -gt 0 ]]; then
            echo "重试挂载系统卷 .........."
        else
            echo ${rslt}
            OK="true"
            break
        fi
    done
    if [[ ${OK} == "true" ]]; then
        break
    else
        sleep ${WAIT}
    fi
done
if [[ "$RETRY_TIMES" -ge 60 ]]; then
    echo "挂载系统卷vol_system失败"
    exit 0
fi
# 向系统卷写入一个标识文件
if [[ ! -f "/vol_system/${POD_HOSTIP}" ]]; then
    echo "hello gluster" > /vol_system/${POD_HOSTIP}
fi
echo "挂载系统卷完成"


#------ 主进程不退出，对于0号节点，开始通过系统卷的内容进行节点增 TODO:删
while true
do
    content=$(gluster peer status)
    echo "######peer status######"
    echo ${content}
    content=$(gluster volume list)
    echo "######volume list######"
    echo ${content}


    if [[ "${podnumber}" -eq 0 ]]; then
        echo "检查节点...."
        boot_node_ip=$(cat /vol_system/boot_node)
        for file in /vol_system/*; do
            info=$(cat ${file})
            # 如果不是初创节点的shadowadmin写入的文件，同时也不是初创node的ip，则加入集群
            if [[ $(basename ${file}) != "boot_node" ]] && [[ $(basename ${file}) != ${boot_node_ip} ]] && [[ ${info} == "hello gluster" ]]; then
                echo "将 $(basename ${file}) 加入集群..."
                # 把节点加入集群
                rslt=$(gluster peer probe $(basename ${file}))
                echo ${rslt}
                # 获取当前的replica数量，循环创建启动配置中设置的卷
                # 由于我们是全节点加入brick，因此peer数量就是brick数量
                cur_peer_count=$(gluster peer status| grep "Number of Peers"| awk '{printf $4}')
                replica_cnt=$(($cur_peer_count+1)) # +1的原因是把自己也算进去，peer status不会返回包含当前节点的数量（可以用pool list，但我不想用）
                array=(${FS_VOLUMES//,/ })
                # 根据配置，循环执行add-brick
                for var in ${array[@]}
                do
                    rslt=$(gluster volume add-brick ${var} replica ${replica_cnt} $(basename ${file}):/glustervolumes/${var} force)  #$(basename ${file})就是node的ip地址
                    echo ${rslt}
                done
                # 修改文件内容，下次就不会再处理这个文件对应的节点
                echo "welcome you peer" > ${file}
            fi

            if [[ ${info} == "hello gluster" ]] && [[ $(basename ${file}) == ${boot_node_ip} ]]; then
                echo "welcome you peer" > ${file}
            fi
        done
    fi
    sleep ${WAIT}
done