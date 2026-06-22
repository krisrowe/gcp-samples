# Summary

A walk-thru guide to learn and fully understand the steps (and/or prepare a demo) of setting up 
a Google Cloud HTTP Load Balancer, entirely from scratch, beginning with the creation of the 
network itself and the machine instances that will be load balanced. 

The unique thing about this guide is that it assumes absolutely NO prior configuration. You should
even be able to create a new account on Google Cloud with an empty project and then immediately run
the steps here without any issues. 

## Caveats

Below are the only known circumstances where the steps in this guide could be insufficient or require
adjustments:
1. Differing organization-level security policies
* Your organization-level policies on Google Cloud may vary from those under which these steps were tested, thus potentially requiring additional steps if certain commands fail with contraint errors. 
2. Running against a pre-existing project
* It would be ideal to create a new project for running the steps in this guide.
* If running these commands against some existing project, there could be name collision, e.g. if a network named `default` already exists, in which case, a minor tweak may be needed, e.g. to choose an alternate network name. 

# Demo Steps
## Create or Identify the Project
Capture the project ID where you're going to run through this exercise.
```
export PROJECT_ID=your-gcp-project-id-here
```
It would be ideal to create a new project instead, with defaults, as mentioned in the Caveats section above.

## Create a new network
Below we use the `default` network, but if this is already in use, then select a different name, but use the alternate name consistently throughout the remainder of this overall exercise.
```
export NETWORK_NAME=default
gcloud compute networks create $NETWORK_NAME --project=${PROJECT_ID} --subnet-mode=auto --bgp-routing-mode=global 
```
### Set up firewall rules to allow access to backend target instances for the load balancer
#### Allow internal clients  port 8080 that the container runs on
For simplicity of this guide/demo, we're allowing all internal clients to access the service
running at port 8080 on the compute instances (VMs), even though our main goal is to allow
the load balancer to access this service as the intended client. However, this will also give
us the option to hit the service directly from another host on the network while testing/debugging.
```
gcloud compute firewall-rules create allow-8080 --project=${PROJECT_ID} --network=projects/${PROJECT_ID}/global/networks/${NETWORK_NAME} --description="Allows connection from any source to any instance on the network using HTTP." --direction=INGRESS --source-ranges=10.128.0.0/9 --action=ALLOW --rules=tcp:8080 
```
### Prepare the network so that internal VMs with no external IP can access the internet, as necessary to pull docker images.
#### Create a Cloud Router
```
gcloud compute routers create nat-router-us-central1 \
    --network ${NETWORK_NAME} \
    --region us-central1
```
#### Set up Cloud NAT on the router
```
gcloud compute routers nats create nat-config \
    --router-region us-central1 \
    --router nat-router-us-central1 \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips
```
#### OPTIONAL: Allow instances to be pinged for diagnostics
```
gcloud compute firewall-rules create default-allow-icmp --project=${PROJECT_ID} --network=projects/${PROJECT_ID}/global/networks/${NETWORK_NAME} --description=Allows\ ICMP\ connections\ from\ any\ source\ to\ any\ instance\ on\ the\ network. --direction=INGRESS --priority=65534 --source-ranges=0.0.0.0/0 --action=ALLOW --rules=icmp
```
#### OPTIONAL: Allow instances to be logged into via SSH for debugging
```
gcloud compute firewall-rules create default-allow-ssh --project=${PROJECT_ID} --network=projects/${PROJECT_ID}/global/networks/${NETWORK_NAME} --description=Allows\ TCP\ connections\ from\ any\ source\ to\ any\ instance\ on\ the\ network\ using\ port\ 22. --direction=INGRESS --priority=65534 --source-ranges=0.0.0.0/0 --action=ALLOW --rules=tcp:22
```
## Set up backend service applications on compute instances (VMs)
### Ensure that Compute API is enabled on this project to allow for VMs to be created
gcloud services enable compute --project=${PROJECT_ID}
### DEPRECATED (SKIP THIS): Give the Cloud Build service account permission to create compute instances.
This should no longer be needed, as we are separately creating the compute instances, outside Cloud Build.
```
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/compute.admin
```
### Run the Cloud Build script to build the stubbed service and containerize it.
```
gcloud builds submit --project=${PROJECT_ID}
```
### Ensure the image is publicly accessible to all users for unauthenticated access, 
This will be applicable when a new VM is spun up below and attempts to pull the image.
```
gsutil iam ch allusers:objectViewer gs://artifacts.${PROJECT_ID}.appspot.com
```
### Create a pair of VMs that run the container image
* the argument `--no-address` ensures the VM does not have a public IP address 
* the argument `--shielded-secure-boot` avoids error for violation of constraints/compute.requireShieldedVm
```
gcloud compute instances create-with-container instance-1 \
    --container-image gcr.io/${PROJECT_ID}/stubbed-service \
    --project=${PROJECT_ID} --zone=us-central1-a --network=${NETWORK_NAME} \
    --no-address --shielded-secure-boot

gcloud compute instances create-with-container instance-2 \
    --container-image gcr.io/${PROJECT_ID}/stubbed-service \
    --project=${PROJECT_ID} --zone=us-central1-a --network=${NETWORK_NAME} \
    --no-address --shielded-secure-boot
```
### Group the VM instances created so they can be load balanced
``` 
gcloud compute instance-groups unmanaged create stub-servers \
    --project=lb-test-374518 --zone=us-central1-a
gcloud compute instance-groups unmanaged set-named-ports stub-servers \
    --project=lb-test-374518 --zone=us-central1-a \
    --named-ports=stubweb:8080
gcloud compute instance-groups unmanaged add-instances stub-servers \
    --project=lb-test-374518 --zone=us-central1-a \
    --instances=instance-1,instance-2
```
## Set up Load Balancing
### Health Checks
#### Allow Google-managed service the access to do health checks for the load balancer we will create
```
gcloud compute firewall-rules create allow-health-check \
    --network=${NETWORK_NAME} \
    --action=allow \
    --direction=ingress \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --rules=tcp:8080
```
#### Configure the parameters for a named health check
```
gcloud compute health-checks create http http-check-8080 --port 8080
```
#### Configure LB Backend
##### Create Backend Service
```
gcloud compute backend-services create stub-backend-service \
    --load-balancing-scheme=EXTERNAL \
    --protocol=HTTP \
    --port-name=stubweb \
    --health-checks=http-check-8080 \
    --global

```
##### Attach Our Instance Group as the Backend for the Backend Service
```
gcloud compute backend-services add-backend stub-backend-service \
    --instance-group=stub-servers \
    --instance-group-zone=us-central1-a \
    --global
```
### Create the Frontend of the Load Balancer
```
gcloud compute url-maps create stub-lb \
    --default-service stub-backend-service
gcloud compute target-http-proxies create stub-lb-proxy \
    --url-map=stub-lb
```
NOTE: add the --address argument with alias below if you reserve a static IP.
``` 
gcloud compute forwarding-rules create http-content-rule \
    --load-balancing-scheme=EXTERNAL \
    --global \
    --target-http-proxy=stub-lb-proxy \
    --ports=80    
```