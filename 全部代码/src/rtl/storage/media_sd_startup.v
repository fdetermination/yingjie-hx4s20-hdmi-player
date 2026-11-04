`timescale 1ns/1ps
// 真实SD SPI/FAT32启动封装：mount/list完成后才开放应用文件命令。
module media_sd_startup #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer POWERUP_CYCLES=CLK_FREQ_HZ/1000,
    parameter integer INIT_DIVIDER=(CLK_FREQ_HZ+799999)/800000,
    parameter integer FAST_DIVIDER=(CLK_FREQ_HZ+49999999)/50000000,
    parameter integer INIT_TIMEOUT_CYCLES=CLK_FREQ_HZ
)(
    input wire clk,rst,restart,
    output wire scan_start,scan_done,scan_error,
    output wire entry_valid,
    input wire entry_ready,
    output wire [87:0] entry_name, output wire [1:0] entry_kind,
    output wire [27:0] entry_cluster,output wire [31:0] entry_size,
    input wire app_cmd_valid,output wire app_cmd_ready,input wire [2:0] app_cmd_op,input wire app_cmd_channel,
    input wire [27:0] app_cmd_cluster,input wire [31:0] app_cmd_size,
    output wire app_done,app_error,app_cancel_ack,app_open_complete,input wire app_abort,
    output wire app_data_valid,input wire app_data_ready,output wire [7:0] app_data_byte,output wire app_file_last,
    output wire sd_cs_n,sd_sclk,sd_mosi,input wire sd_miso,
    output wire init_done,high_capacity,init_error,output wire [3:0] sd_error_code,
    output wire [7:0] error_detail,
    output wire [7:0] error_r1
);
    wire service_cmd_valid,service_cmd_ready,service_cmd_channel;
    wire [2:0] service_cmd_op;wire [27:0] service_cmd_cluster;wire [31:0] service_cmd_size;
    wire service_done,service_error,service_cancel_ack,service_abort,service_open_complete;
    wire service_entry_valid,service_entry_ready;wire [87:0] service_entry_name;wire [1:0] service_entry_kind;
    wire [27:0] service_entry_cluster;wire [31:0] service_entry_size;
    wire service_data_valid,service_data_ready;wire [7:0] service_data_byte;wire service_file_last;
    wire reader_cmd_valid,reader_cmd_ready,reader_cmd_channel,reader_done,reader_error,reader_abort,reader_cancel_ack;
    wire [2:0] reader_cmd_op;wire [27:0] reader_cmd_cluster;wire [31:0] reader_cmd_size;
    wire reader_open_complete;
    wire reader_reinitialize;
    wire [3:0] reader_error_code;
    reg [3:0] first_sd_error,first_file_error;
    wire [7:0] sd_response_byte;
    reg [7:0] first_sd_r1;
    reg file_error_saved;
    assign error_detail={first_file_error,first_sd_error};
    assign error_r1=first_sd_r1;
    always @(posedge clk or posedge rst)begin
        if(rst)begin first_sd_error<=0;first_file_error<=0;first_sd_r1<=0;file_error_saved<=0;end
        else if(restart || reader_reinitialize)begin first_sd_error<=0;first_file_error<=0;first_sd_r1<=0;file_error_saved<=0;end
        else begin
            // SPI取消会清原始码，在取消结束前保存本轮第一次失败。
            if(first_sd_error==0 && sd_error_code!=0)begin
                first_sd_error<=sd_error_code;
                // fail(6)后的下一拍早于取消FF完成，原R1仍在接收寄存器中。
                first_sd_r1<=sd_error_code==6?{1'b0,sd_response_byte[6:0]}:8'd0;
            end
            if(reader_error && !file_error_saved)begin first_file_error<=reader_error_code;file_error_saved<=1;end
        end
    end
    wire reader_data_valid,reader_data_ready,reader_file_last;wire [7:0] reader_data_byte;
    media_storage_mux mux(
        .clk(clk),.rst(rst),.restart(restart),.scan_start(scan_start),.scan_done(scan_done),.scan_error(scan_error),
        .reader_reinitialize(reader_reinitialize),
        .entry_valid(entry_valid),.entry_ready(entry_ready),.entry_name(entry_name),.entry_kind(entry_kind),.entry_cluster(entry_cluster),.entry_size(entry_size),
        .app_cmd_valid(app_cmd_valid),.app_cmd_ready(app_cmd_ready),.app_cmd_op(app_cmd_op),.app_cmd_channel(app_cmd_channel),.app_cmd_cluster(app_cmd_cluster),.app_cmd_size(app_cmd_size),
        .app_done(app_done),.app_error(app_error),.app_cancel_ack(app_cancel_ack),.app_open_complete(app_open_complete),.app_abort(app_abort),.app_data_valid(app_data_valid),.app_data_ready(app_data_ready),.app_data_byte(app_data_byte),.app_file_last(app_file_last),
        .service_cmd_valid(service_cmd_valid),.service_cmd_ready(service_cmd_ready),.service_cmd_op(service_cmd_op),.service_cmd_channel(service_cmd_channel),.service_cmd_cluster(service_cmd_cluster),.service_cmd_size(service_cmd_size),
        .service_done(service_done),.service_error(service_error),.service_open_complete(service_open_complete),.service_init_error(init_error),.service_cancel_ack(service_cancel_ack),.service_abort(service_abort),
        .service_entry_valid(service_entry_valid),.service_entry_ready(service_entry_ready),.service_entry_name(service_entry_name),.service_entry_kind(service_entry_kind),.service_entry_cluster(service_entry_cluster),.service_entry_size(service_entry_size),
        .service_data_valid(service_data_valid),.service_data_ready(service_data_ready),.service_data_byte(service_data_byte),.service_file_last(service_file_last));
    // 初始化失败时文件层尚无块事务；普通文件abort不会触达SPI初始化状态机。
    wire reader_reset=rst || (restart && !init_done) || reader_reinitialize;
    file_command_bridge commands(
        .clk(clk),.rst(rst),.app_abort(service_abort),.app_cmd_valid(service_cmd_valid),.app_cmd_ready(service_cmd_ready),
        .app_cmd_op(service_cmd_op),.app_cmd_channel(service_cmd_channel),.app_cmd_cluster(service_cmd_cluster),.app_cmd_size(service_cmd_size),
        .app_done(service_done),.app_error(service_error),.app_open_complete(service_open_complete),.app_cancel_ack(service_cancel_ack),.app_data_valid(service_data_valid),
        .app_data_ready(service_data_ready),.app_data_byte(service_data_byte),.app_file_last(service_file_last),
        .service_cmd_valid(reader_cmd_valid),.service_cmd_ready(reader_cmd_ready),.service_cmd_op(reader_cmd_op),
        .service_cmd_channel(reader_cmd_channel),.service_cmd_cluster(reader_cmd_cluster),.service_cmd_size(reader_cmd_size),
        .service_done(reader_done),.service_error(reader_error),.service_open_complete(reader_open_complete),.service_cancel_ack(reader_cancel_ack),.service_abort(reader_abort),
        .service_data_valid(reader_data_valid),.service_data_ready(reader_data_ready),.service_data_byte(reader_data_byte),.service_file_last(reader_file_last));
    sd_fat32_reader #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.POWERUP_CYCLES(POWERUP_CYCLES),
        .INIT_DIVIDER(INIT_DIVIDER),.FAST_DIVIDER(FAST_DIVIDER),.INIT_TIMEOUT_CYCLES(INIT_TIMEOUT_CYCLES)) reader(
        .clk(clk),.rst(reader_reset),.abort(reader_abort),.cmd_valid(reader_cmd_valid),.cmd_ready(reader_cmd_ready),.cmd_op(reader_cmd_op),.cmd_channel(reader_cmd_channel),.cmd_cluster(reader_cmd_cluster),.cmd_size(reader_cmd_size),
        .busy(),.mounted(),.done(reader_done),.error(reader_error),.open_complete(reader_open_complete),.cancel_ack(reader_cancel_ack),.error_code(reader_error_code),.entry_valid(service_entry_valid),.entry_ready(service_entry_ready),.entry_name(service_entry_name),.entry_kind(service_entry_kind),.entry_cluster(service_entry_cluster),.entry_size(service_entry_size),
        .data_valid(reader_data_valid),.data_ready(reader_data_ready),.data_byte(reader_data_byte),.file_last(reader_file_last),.sd_cs_n(sd_cs_n),.sd_sclk(sd_sclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),.init_done(init_done),.high_capacity(high_capacity),.init_error(init_error),.sd_error_code(sd_error_code),.sd_response_byte(sd_response_byte));
endmodule
