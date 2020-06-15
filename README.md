# simplest glusterfs helm chart
maybe the simplest helm chart of glusterfs-centos4u1 application, with no complex ENV setup

# Very easy to setup

this application is the simplest way to deploy glusterfs container on kubernetes. It is based on gluster/gluster-kubernetes, but, there's heketi need!

it's very fun that:
1. you don't need install gluster-fuse or client on your node
2. you dont't need heketi
3. you can setup a cluster only one node (you don't need at least 2 or 3 node)
4. if you use rancher, you need only fill node's ips and volume names of glusterfs.

# How

because I want to build a contanierd glusterfs system on k8s, but I found that it's not easy for somebody because you need to setup very complex envirment, and you need at least 2 or 3 or more node (based on glusterfs system), and you must use heketi.

But, I only want to:
1. simply pull and start the glusterfs container
2. I don't want to use heketi because I want to manange my custom PV
3. maybe I have only one Node

So... I try to make it this way:

a helm app with two SatefulSet k8s object
- a) one is glusterfs centos4u1 (because PVC use 4.1 client to mount). 
And with a shell command that:
  -- 1) init some special things, mount self to the \_\_vol_system__ volume
  -- 2) loop to find new node in \_\_vol_system__ volume
  -- 3) probe new node in the cluster
- b) another one is a boot pod named "shadowadmin", it's the key that:
  -- 1) init some special things
  -- 2) listen StatefulSet-0 glusterfs centos4u1 start
  -- 3) probe StatefulSet-0 glusterfs centos4u1 in gluster
  -- 4) create a \_\_vol_system__ volume, and add bricks
  -- 5) create all voluem defined in the helm yaml, and add bricks
  -- 5) remove all brick of shadowadmin out of the gluster
after that down, you got a "one node" glusterfs cluster, and because of (StatefulSet-0 glusterfs centos4u1)'s shell, you can setup one or more node.
 
 
***note that, in github, I only push replica model***


# Need help

As you can see, this based on StatutfulSet object and "HostNetwork", that means you could just run one glusterfs pod in a node.
The PV and PVC's behavior that it use EndPoint to find glusterfs's ip,if you dont't use hostNetwork, you'll found an error that says such like "xxx-0.xxx could not resovle", because the pv plugin now can not access the StatufulSet glusterfs pod's dns without **namespace**, and EndPoint only support selector or IP.

so if there is a new pv plugin, just tell me!

