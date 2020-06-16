#!/usr/bin/env bash

[pipeline:main]
pipeline = proxy-logging cache s3api tempauth bulk slo proxy-logging proxy-server
When using keystone, the config will be:

[pipeline:main]
pipeline = proxy-logging cache authtoken s3api s3token keystoneauth bulk slo proxy-logging proxy-server
Finally, add the s3api middleware section:

[filter:s3api]
use = egg:swift#s3api