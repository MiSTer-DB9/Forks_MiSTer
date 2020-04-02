FROM <<QUARTUS_IMAGE>>
WORKDIR /project
ADD . /project
RUN /opt/intelFPGA_lite/quartus/bin/quartus_sh --flow compile <<COMPILATION_INPUT>>
CMD cat /project/<<COMPILATION_OUTPUT>>
