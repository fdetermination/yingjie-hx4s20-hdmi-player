`timescale 1ns/1ps
// 自主像素流/PCM到厂商HDMI协议Core的完整应用接口。
// 输入由已对齐的video_pixel_pipeline提供；line_fault必须通知上层停止/排空/重新同步。
module hdmi_av_output #(
    parameter integer PIXEL_HZ=74250000,VIDEO_WIDTH=1280,VIDEO_HEIGHT=720,LINE_BUFFER_BITS=12
)(
    input wire clk,rst,pixel_valid,
    input wire [10:0] x,y,
    input wire [23:0] pixel_rgb,
    input wire scene_valid,
    input wire [7:0] scene_token,
    output wire scene_sof,scene_sof_valid,
    output wire [7:0] scene_sof_token,
    input wire sample_valid,
    input wire signed [15:0] sample_left,sample_right,
    input wire edid_start,
    output wire edid_valid,
    output wire [7:0] edid_data,
    output wire line_fault,video_locked,ddc_scl,
    inout wire ddc_sda,
    output wire [9:0] tmds0,tmds1,tmds2,tmds_clock
);
    wire valid,ready,sof,eol;wire [23:0] rgb;
    wire tagged_valid;wire [7:0] tagged_token;
    video_line_bridge #(.WIDTH(VIDEO_WIDTH),.HEIGHT(VIDEO_HEIGHT),.BUFFER_BITS(LINE_BUFFER_BITS)) lines(.clk(clk),.rst(rst),.pixel_valid(pixel_valid),.pixel_rgb(pixel_rgb),.x(x),.y(y),
        .scene_valid(scene_valid),.scene_token(scene_token),.axis_scene_valid(tagged_valid),.axis_scene_token(tagged_token),
        .axis_ready(ready),.axis_valid(valid),.axis_sof(sof),.axis_eol(eol),.axis_rgb(rgb),.fault(line_fault),.fault_code());
    assign scene_sof=valid && ready && sof && !line_fault && !rst;
    assign scene_sof_valid=tagged_valid;assign scene_sof_token=tagged_token;
    hdmi_vendor_tx_720p #(.PIXEL_HZ(PIXEL_HZ)) tx(.clk(clk),.rst(rst),.video_valid(valid),.video_sof(sof),
        .video_eol(eol),.video_rgb(rgb),.video_ready(ready),.sample_valid(sample_valid),
        .sample_left(sample_left),.sample_right(sample_right),.edid_start(edid_start),.edid_valid(edid_valid),
        .edid_data(edid_data),.video_locked(video_locked),.ddc_scl(ddc_scl),.ddc_sda(ddc_sda),
        .tmds0(tmds0),.tmds1(tmds1),.tmds2(tmds2),.tmds_clock(tmds_clock));
endmodule
