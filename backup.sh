#!/bin/bash

instanceid=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
azone=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
region=${azone/%?/}

AWS_CMD="aws --region $region"

create_snapshot() {
    instance_id=$1
    instance_name=$(${AWS_CMD} ec2 describe-instances --instance-ids ${instance_id} --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text)
    echo "Create snapshot Start"
    volumes=($(${AWS_CMD} ec2 describe-instances --instance-ids ${instance_id} --query "Reservations[].Instances[].BlockDeviceMappings[].Ebs[].VolumeId" --output text))
    if [ -z "${volumes[@]}" ] ; then
        echo "[ERROR] ec2-describe-instances: Can not get volumes. ${instance_id}"
        exit 1
    fi
    for vol_id in "${volumes[@]}"
    do
        echo "volume-id : ${vol_id}"
        snapshot_id=$(${AWS_CMD} ec2 create-snapshot --volume-id ${vol_id} --description "Automate backup from ${vol_id}" --output text | awk '{print $10}')
        if [ $? != 0 ] ; then
            echo "[ERROR] ec2-create-snapshot ${vol_id}"
            exit 1
        fi
        echo "snapshot-id : ${snapshot_id}"
        ${AWS_CMD} ec2 create-tags --resources ${snapshot_id} --tags "Key=Name,Value=${instance_name}(${instance_id})" "Key=Backup-Type,Value=auto" "Key=InstanceId,Value=${instance_id}" "Key=VolumeId,Value=${vol_id}" > /dev/null
    done
    echo "Create snapshot finished"
}

delete_snapshot() {
    instance_id=$1
    echo "Delete snapshot Start"
    generation=$(${AWS_CMD} ec2 describe-instances --instance-ids ${instance_id} --query 'Reservations[].Instances[].Tags[?Key==`Backup-Generation`][].Value' --output text)
    if [ -z $generation ] ; then
        echo "[ERROR] ec2-describe-instances: Can not get Backup-Generation. ${instance_id}"
        exit 1
    fi
    volumes=($(${AWS_CMD} ec2 describe-instances --instance-ids ${instance_id} --query "Reservations[].Instances[].BlockDeviceMappings[].Ebs[].VolumeId" --output text))
    if [ -z "${volumes[@]}" ] ; then
        echo "[ERROR] ec2-describe-instances: Can not get volumes. ${instance_id}"
        exit 1
    fi
    for vol_id in "${volumes[@]}"
    do
        echo "volume-id : ${vol_id}"
        snapshots=($(${AWS_CMD} ec2 describe-snapshots --filters "Name=tag:Backup-Type,Values=auto" "Name=tag:VolumeId,Values=${vol_id}" --query "sort_by(Snapshots,&StartTime)[].SnapshotId" --output text))
        cnt=${#snapshots[@]}
        echo "Found ${cnt} snapshots (${snapshots[@]})"
        for snapshot_id in "${snapshots[@]}"
        do
            if [ $cnt -gt $generation ] ; then
                echo "Delete snapshot-id : ${snapshot_id}"
                ${AWS_CMD} ec2 delete-snapshot --snapshot-id ${snapshot_id} > /dev/null
                if [ $? != 0 ] ; then
                    echo "[ERROR] ec2-delete-snapshot: ${snapshot_id}"
                    exit 1
                fi
            fi
            cnt=`expr $cnt - 1`
        done
    done
    echo "Delete old snapshot End"
}

instances=($(${AWS_CMD} ec2 describe-instances --region ap-northeast-1 --output text --filters "Name=tag:Backup-Generation,Values=*" --query "Reservations[].Instances[].InstanceId" --output text))

for instance_id in "${instances[@]}"
do
    create_snapshot $instance_id
    delete_snapshot $instance_id
done
