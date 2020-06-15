#!/bin/sh


# 这是一个名叫Shadowadmin的pod
# 作用：由于glusterfs的replica卷，要求至少有两个peer才能创建
# 因此，这个pod作为一个shadowadmin，在且仅在podindex为1的时候启动
# 目的是让gluster-0能够add peer，组建replica卷
# 当gluster-0启动后，它的脚本会执行add peer等操作
# 完成后，进入空转状态，控制权交给gluster-0

echo "当前POD：$POD_NAME "
podnumber=${POD_NAME:0-1}

if [ "`expr $podnumber + 1`" -gt "1" ]; then
   echo "当前POD仅能启动1个"
   exit 1
fi

# 启动glusterfs
# @see https://github.com/gluster/gluster-kubernetes/issues/298
nohup /usr/lib/systemd/systemd --system 2>&1 &

# @see ./shadowadmin.sh——完成之后会生成一个shadowadmin__inited__文件
if [[ -f "/glustervolumes/shadowadmin__inited__" ]]; then
    echo "已经初始化过了，无需再初始化"
else
    # 在一分钟之内探测glusterfs-0是否启动
    WAIT=10
    RETRY_TIMES=0

    while [[ ${RETRY_TIMES} -lt 60 ]]; do
        ((RETRY_TIMES++))
        echo -n "Check ${HEADLESS_GLUSTERFS_0} $RETRY_TIMES times"
        echo ".............................." && sleep ${WAIT}

        #
        content=$(ping  ${HEADLESS_GLUSTERFS_0} -c 2 -n)
        echo ${content}
        # 获取字符串长度
        len=${#content}
        # 获取0 received的位置
        idx=$(echo ${content} | awk -F '0 received' '{print $1}' | wc -c)

        # 如果经过awk分割后，wc的结果和字符串长度一样，则表示没有找到0 received
        if [[ "$idx" -ge "$len"  ]]; then
            echo "glusterfs-0已经上线"
            break
        fi

        echo "重试: ping  ${HEADLESS_GLUSTERFS_0} -c 2 -n"
    done

    if [[ "$RETRY_TIMES" -ge 60 ]]; then
        echo "重试超时。无法获取到glusterfs-0状态"
        exit 0
    fi

    # 启动shadowadmin
    # TODO: 支持“rancher更新”，也就是可以新增和删除卷

    WAIT=10
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

    # 把glusterfs-0加入集群
    while [[ ${RETRY_TIMES} -lt 60 ]]; do
        ((RETRY_TIMES++))
        echo -n "把glusterfs-0加入集群 $RETRY_TIMES times"
        echo ".............................." && sleep ${WAIT}

        # 因为是hostnetwork模式，这里直接加入的其实是当前node，也就是gluster-0
        content=$(gluster peer probe ${POD_HOSTIP})
        echo ${content}
        idx=$(echo ${content}| grep "peer probe: success."|wc -c)
        if [[ ${idx} -gt 0 ]]; then
            echo "glusterfs-0成功加入集群"
            break
        fi

        echo "重试把glusterfs-0加入集群"
    done

    if [[ "$RETRY_TIMES" -ge 60 ]]; then
        echo "把glusterfs-0加入集群超时。无法加入"
        exit 0
    fi


    # 开始创建需要的卷

    # 创建一个内部的system卷，用来节点间业务沟通
    #                                                                                      这里也是用的当前node的ip作为一个peer，因为是hostnetwork模式（见89行）
    echo "创建一个内部的system卷，用来节点间业务沟通"
    echo "gluster volume create vol_system replica 2 ${POD_PODIP}:/glustervolumes/__vol_system__ ${POD_HOSTIP}:/glustervolumes/__vol_system__ force"
    rslt=$(gluster volume create vol_system replica 2 ${POD_PODIP}:/glustervolumes/__vol_system__ ${POD_HOSTIP}:/glustervolumes/__vol_system__ force)
    echo ${rslt}
    echo "gluster volume start vol_system"
    rslt=$(gluster volume start vol_system)
    echo ${rslt}
    # replica卷已经建好了，此时可以将自己这份brick移除
    rslt=$(echo "y"|gluster volume remove-brick vol_system replica 1 ${POD_PODIP}:/glustervolumes/__vol_system__ force)
    echo ${rslt}

    echo "挂载系统卷...."
    #------ 挂载内部系统卷，并且写入一个标志文件。由于这里是shadowadmin，因此，这里写入的hostip也就是整个集群的初创node
    mkdir -p /vol_system
    RETRY_TIMES=0
    while [[ ${RETRY_TIMES} -lt 60 ]]; do
        echo "mount -t glusterfs ${POD_HOSTIP}:vol_system /vol_system"
        rslt=$(mount -t glusterfs ${POD_HOSTIP}:vol_system /vol_system 2>&1)
        echo "挂载系统卷结果：${rslt}"
        rslt=$(echo ${rslt} |grep "failed\|ERROR:"|wc -c)
        echo ${rslt}
        if [[ ${rslt} -gt 0 ]]; then
            echo "重试挂载系统卷 .........." && sleep ${WAIT}
        else
            echo ${rslt}
            break
        fi
    done
    if [[ "$RETRY_TIMES" -ge 60 ]]; then
        echo "挂载系统卷vol_system失败"
        exit 0
    fi
    # 向系统卷写入一个标识文件
    echo "${POD_HOSTIP}" > /vol_system/boot_node
    echo "挂载系统卷完成"


    # 循环创建启动配置中设置的卷
    array=(${FS_VOLUMES//,/ })
    for var in ${array[@]}
    do
        mkdir -p /glustervolumes/${var}
        #                                                                              这里也是用的当前node的ip作为一个peer，因为是hostnetwork模式（见89行）
        echo "创建${var}卷. gluster volume create ${var} replica 2 ${POD_PODIP}:/glustervolumes/${var} ${POD_HOSTIP}:/glustervolumes/${var} force"
        rslt=$(gluster volume create ${var} replica 2 ${POD_PODIP}:/glustervolumes/${var} ${POD_HOSTIP}:/glustervolumes/${var} force)
        echo ${rslt}
        echo "启动${var}卷. gluster volume start ${var}"
        rslt=$(gluster volume start ${var})
        echo ${rslt}
    done
    # replica卷已经建好了，此时可以将自己这份brick移除
    # 只是作为peer在集群中存在。当然，因为是peer，所以可以执行各种命令
    for var in ${array[@]}
    do
        rslt=$(echo "y"|gluster volume remove-brick ${var} replica 1 ${POD_PODIP}:/glustervolumes/${var} force)
        echo ${rslt}
    done


    echo "inited" > /glustervolumes/shadowadmin__inited__
fi


# 主进程不退出
while true
do
    content=$(gluster peer status)
    echo "######peer status######"
    echo ${content}
    content=$(gluster volume list)
    echo "######volume list######"
    echo ${content}
    sleep 10
done

