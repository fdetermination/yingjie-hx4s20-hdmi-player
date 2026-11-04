`timescale 1ns/1ps
// 物理SD SPI与文件服务的自主整合：init_done前禁止文件命令被接受。
module sd_fat32_reader #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer POWERUP_CYCLES=CLK_FREQ_HZ/1000,
    parameter integer INIT_DIVIDER=125,FAST_DIVIDER=2,
    parameter integer INIT_TIMEOUT_CYCLES=CLK_FREQ_HZ,
    parameter integer TOKEN_TIMEOUT_CYCLES=CLK_FREQ_HZ/10,
    parameter integer BLOCK_TIMEOUT_CYCLES=CLK_FREQ_HZ/2,
    parameter integer MAX_CHAIN_HOPS=1_048_576,MAX_DIRECTORY_ENTRIES=4096
)(
    input wire clk,rst,abort,cmd_valid,
    output wire cmd_ready,
    input wire [2:0] cmd_op,
    input wire cmd_channel,
    input wire [27:0] cmd_cluster,
    input wire [31:0] cmd_size,
    output wire busy,mounted,done,error,cancel_ack,open_complete,
    output wire [3:0] error_code,
    output wire entry_valid,
    input wire entry_ready,
    output wire [87:0] entry_name,
    output wire [1:0] entry_kind,
    output wire [27:0] entry_cluster,
    output wire [31:0] entry_size,
    output wire data_valid,
    input wire data_ready,
    output wire [7:0] data_byte,
    output wire file_last,
    output wire sd_cs_n,sd_sclk,sd_mosi,
    input wire sd_miso,
    output wire init_done,high_capacity,init_error,
    output wire [3:0] sd_error_code,
    output wire [7:0] sd_response_byte
);
    wire service_ready,block_req,block_accept,block_valid,block_ready;
    wire [31:0] block_lba;
    wire [7:0] block_data;
    wire block_last,block_error,block_cancel,block_cancel_ack;
    assign cmd_ready=service_ready && init_done;
    assign init_error=block_error && !init_done;
    fat32_file_service #(.BLOCK_TIMEOUT_CYCLES(BLOCK_TIMEOUT_CYCLES),
        .MAX_CHAIN_HOPS(MAX_CHAIN_HOPS),.MAX_DIRECTORY_ENTRIES(MAX_DIRECTORY_ENTRIES)) files(
        .clk(clk),.rst(rst),.abort(abort),.cmd_valid(cmd_valid && init_done),.cmd_ready(service_ready),
        .cmd_op(cmd_op),.cmd_channel(cmd_channel),.cmd_cluster(cmd_cluster),.cmd_size(cmd_size),
        .busy(busy),.mounted(mounted),.done(done),.error(error),.cancel_ack(cancel_ack),.open_complete(open_complete),.error_code(error_code),
        .entry_valid(entry_valid),.entry_ready(entry_ready),.entry_name(entry_name),.entry_kind(entry_kind),
        .entry_cluster(entry_cluster),.entry_size(entry_size),.data_valid(data_valid),.data_ready(data_ready),
        .data_byte(data_byte),.file_last(file_last),.block_req(block_req),.block_accept(block_accept),
        .block_lba(block_lba),.block_valid(block_valid),.block_ready(block_ready),.block_data(block_data),
        .block_last(block_last),.block_error(block_error),.block_cancel(block_cancel),.block_cancel_ack(block_cancel_ack));
    sd_spi_block_reader #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.POWERUP_CYCLES(POWERUP_CYCLES),
        .INIT_DIVIDER(INIT_DIVIDER),.FAST_DIVIDER(FAST_DIVIDER),.INIT_TIMEOUT_CYCLES(INIT_TIMEOUT_CYCLES),
        .TOKEN_TIMEOUT_CYCLES(TOKEN_TIMEOUT_CYCLES)) card(
        .clk(clk),.rst(rst),.abort(block_cancel),.block_req(block_req),.block_accept(block_accept),
        .block_lba(block_lba),.block_valid(block_valid),.block_ready(block_ready),.block_data(block_data),
        .block_last(block_last),.block_error(block_error),.block_cancel_ack(block_cancel_ack),
        .sd_cs_n(sd_cs_n),.sd_sclk(sd_sclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso),
        .init_done(init_done),.high_capacity(high_capacity),.error_code(sd_error_code),.response_byte(sd_response_byte));
endmodule
