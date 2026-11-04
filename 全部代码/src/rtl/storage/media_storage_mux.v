`timescale 1ns/1ps
// 存储启动/目录扫描/应用文件命令仲裁。下游可以是sd_fat32_reader或模型服务。
// 上电先mount，再list；目录完成后才把文件命令ready交给应用层。
module media_storage_mux(
    input wire clk,rst,restart,
    output reg scan_start,scan_done,scan_error,
    output wire reader_reinitialize,
    output wire entry_valid,
    input wire entry_ready,
    output wire [87:0] entry_name,
    output wire [1:0] entry_kind,
    output wire [27:0] entry_cluster,
    output wire [31:0] entry_size,
    input wire app_cmd_valid,
    output wire app_cmd_ready,
    input wire [2:0] app_cmd_op,
    input wire app_cmd_channel,
    input wire [27:0] app_cmd_cluster,
    input wire [31:0] app_cmd_size,
    output wire app_done,app_error,app_cancel_ack,app_open_complete,
    input wire app_abort,
    output wire app_data_valid,
    input wire app_data_ready,
    output wire [7:0] app_data_byte,
    output wire app_file_last,
    output wire service_cmd_valid,
    input wire service_cmd_ready,
    output wire [2:0] service_cmd_op,
    output wire service_cmd_channel,
    output wire [27:0] service_cmd_cluster,
    output wire [31:0] service_cmd_size,
    input wire service_done,service_error,service_init_error,service_cancel_ack,service_open_complete,
    output wire service_abort,
    input wire service_entry_valid,
    output wire service_entry_ready,
    input wire [87:0] service_entry_name,
    input wire [1:0] service_entry_kind,
    input wire [27:0] service_entry_cluster,
    input wire [31:0] service_entry_size,
    input wire service_data_valid,
    output wire service_data_ready,
    input wire [7:0] service_data_byte,
    input wire service_file_last
);
    localparam MOUNT=0,MOUNT_WAIT=1,LIST=2,LIST_WAIT=3,READY=4,FAILED=5,RESTART_DRAIN=6,REINITIALIZE=7;
    reg [2:0] state;
    assign reader_reinitialize=state==REINITIALIZE && !rst;
    wire mount_cmd=state==MOUNT,list_cmd=state==LIST;
    assign service_cmd_valid=!service_abort && !service_init_error &&
        ((mount_cmd||list_cmd)?1'b1:(state==READY?app_cmd_valid:1'b0));
    assign service_cmd_op=mount_cmd?3'd0:(list_cmd?3'd1:app_cmd_op);
    assign service_cmd_channel=(mount_cmd||list_cmd)?1'b0:app_cmd_channel;
    assign service_cmd_cluster=(mount_cmd||list_cmd)?28'd0:app_cmd_cluster;
    assign service_cmd_size=(mount_cmd||list_cmd)?32'd0:app_cmd_size;
    assign app_cmd_ready=state==READY && service_cmd_ready && !service_abort;
    assign app_done=state==READY && service_done;
    assign app_error=state==READY && service_error;
    assign app_open_complete=state==READY && service_done && !service_error && service_open_complete;
    assign app_cancel_ack=(state==READY || state==RESTART_DRAIN) && service_cancel_ack;
    assign service_abort=app_abort || restart || state==FAILED || state==RESTART_DRAIN;
    assign entry_valid=state==LIST_WAIT && service_entry_valid;
    assign service_entry_ready=state==LIST_WAIT && entry_ready;
    assign app_data_valid=state==READY && service_data_valid;
    assign service_data_ready=state==READY && app_data_ready;
    assign app_data_byte=service_data_byte;
    assign app_file_last=service_file_last;
    // 描述符直通但只在目录扫描态开放；应用查询在READY态之后才可能发生。
    assign entry_name=service_entry_name;assign entry_kind=service_entry_kind;
    assign entry_cluster=service_entry_cluster;assign entry_size=service_entry_size;
    always @(posedge clk or posedge rst)begin
        if(rst)begin state<=MOUNT;scan_start<=0;scan_done<=0;scan_error<=0;end
        else begin
            scan_start<=0;scan_done<=0;scan_error<=0;
            if(restart)state<=RESTART_DRAIN;
            else case(state)
                MOUNT:if(service_init_error)begin state<=FAILED;scan_error<=1;end
                      else if(service_cmd_valid && service_cmd_ready)state<=MOUNT_WAIT;
                MOUNT_WAIT:if(service_error || service_init_error)begin state<=FAILED;scan_error<=1;end else if(service_done)begin state<=LIST;scan_start<=1;end
                LIST:if(service_cmd_ready)state<=LIST_WAIT;
                LIST_WAIT:if(service_error)begin state<=FAILED;scan_error<=1;end else if(service_done)begin state<=READY;scan_done<=1;end
                READY:if(app_abort && service_cancel_ack)state<=READY;
                FAILED:if(!restart)state<=FAILED;
                // restart不能切断应用的取消应答；所有权释放后才重新挂载。
                // 取消已确认且应用owner已释放，才允许重新初始化卡驱动。
                RESTART_DRAIN:if(service_cancel_ack && !app_abort)state<=REINITIALIZE;
                REINITIALIZE:state<=MOUNT;
            endcase
        end
    end
endmodule
