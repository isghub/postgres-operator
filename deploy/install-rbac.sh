#!/bin/bash

# Copyright 2018 - 2020 Crunchy Data Solutions, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

$DIR/cleanup-rbac.sh

if [[ $(oc version) =~ "openshift" ]]; then
	# create PGO SCC used with pgclusters (must use 'oc' not 'kubectl')
	oc create -f $DIR/pgo-scc.yaml
fi

# see if CRDs need to be created
$PGO_CMD get crd pgclusters.crunchydata.com > /dev/null
if [ $? -eq 1 ]; then
	$PGO_CMD create -f $DIR/crd.yaml
fi

# create the initial pgo admin credential
$DIR/install-bootstrap-creds.sh

# create the Operator service accounts
expenv -f $DIR/service-accounts.yaml | $PGO_CMD --namespace=$PGO_OPERATOR_NAMESPACE create -f -

if [ -r "$PGO_IMAGE_PULL_SECRET_MANIFEST" ]; then
	$PGO_CMD -n $PGO_OPERATOR_NAMESPACE create -f "$PGO_IMAGE_PULL_SECRET_MANIFEST"
fi

if [ -n "$PGO_IMAGE_PULL_SECRET" ]; then
	patch='{"imagePullSecrets": [{ "name": "'"$PGO_IMAGE_PULL_SECRET"'" }]}'

	$PGO_CMD -n $PGO_OPERATOR_NAMESPACE patch --type=strategic --patch="$patch" serviceaccount/postgres-operator
fi

# Create the proper cluster roles corresponding to the namespace mode configured for the
# current Operator install.  The namespace mode selected will determine which cluster roles are
# created for the Operator Service Account, with those cluster roles (or the absence thereof)
# providing the various describe across the various modes below:
#
# A value of "dynamic" enables full dynamic namespace capabilities, in which the Operator can
# create, delete and update any namespaces within the Kubernetes cluster, while then also having 
# the ability to create the roles, role bindings and service accounts within those namespaces as
# required for the Operator to create PG clusters.  Additionally, while in this mode the Operator
# can listen for namespace events (e.g. namespace additions, updates and deletions), and then create
# or remove controllers for various namespaces as those namespaces are added or removed from the
# Kubernetes cluster and/or Operator install.
# 
# If a value of "readonly" is provided, the Operator is still able to listen for namespace events
# within the  Kubernetetes cluster, and then create and run and/or remove controllers as namespaces
# are added and deleted.  However, while in this mode the Operator is unable to create, delete or
# update namespaces, nor can it create the RBAC it requires in any of those namespaces to create PG
# clusters.  Therefore,  while in a "readonly" mode namespaces must be pre-configured with the proper
# RBAC, since the Operator cannot create the RBAC itself.
#
# And finally, if "disabled" is selected, then namespace capabilities will be disabled altogether
# In this mode the Operator will simply attempt to work with the target namespaces specified during 
# installation.  If no target namespaces are specified, then it will be configured to work within the
# namespace in which it is deployed.
if [[ "${PGO_NAMESPACE_MODE:-dynamic}" == "dynamic" ]]; then
	# create the full cluster roles for the Operator
	expenv -f $DIR/cluster-roles.yaml | $PGO_CMD create -f -
	# create the cluster role binding for the Operator Service Account
	expenv -f $DIR/cluster-role-bindings.yaml | $PGO_CMD --namespace=$PGO_OPERATOR_NAMESPACE create -f -
	echo "Cluster roles installed to enable dynamic namespace capabilities"
elif [[ "${PGO_NAMESPACE_MODE}" == "readonly" ]]; then
	# create the read-only cluster roles for the Operator
	expenv -f $DIR/cluster-roles-readonly.yaml | $PGO_CMD create -f -
	# create the cluster role binding for the Operator Service Account
	expenv -f $DIR/cluster-role-bindings.yaml | $PGO_CMD --namespace=$PGO_OPERATOR_NAMESPACE create -f -
	echo "Cluster roles installed to enable read-only namespace capabilities"
elif [[ "${PGO_NAMESPACE_MODE}" == "disabled" ]]; then
	echo "Cluster roles not installed, namespace capabilites will be disabled"
fi

# Create the roles the Operator requires within it's own namespace
expenv -f $DIR/roles.yaml | $PGO_CMD -n $PGO_OPERATOR_NAMESPACE create -f -
expenv -f $DIR/role-bindings.yaml | $PGO_CMD -n $PGO_OPERATOR_NAMESPACE create -f -

# create the keys used for pgo API
source $DIR/gen-api-keys.sh
