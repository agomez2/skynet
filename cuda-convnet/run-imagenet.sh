#!/bin/bash

#gdb -ex run --args 
python convnet.py \
  --data-path=/scratch/power/imagenet/batch-32 \
  --save-path=/scratch/power/tmp \
  --gpu=0 \
  --test-range=4 \
  --train-range=0-3 \
  --layer-def=./imagenet-32.cfg \
  --layer-params=./imagenet-params.cfg \
  --data-provider=imagenet \
  --test-freq=13 \
  --mini=1
