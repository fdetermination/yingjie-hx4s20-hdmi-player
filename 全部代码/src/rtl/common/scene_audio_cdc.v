`timescale 1ns/1ps
// 有序场景mailbox：arm先确认接收，真实带token的HDMI SOF触发；取消握手优先。
module scene_audio_cdc #(
    parameter integer TOKEN_BITS=8
)(
    input wire src_clk,dst_clk,rst,
    input wire arm_valid,arm_slot,arm_has_audio,cancel,
    input wire [TOKEN_BITS-1:0] arm_token,
    output wire arm_ready,armed,cancel_ack,
    output reg started,error,
    output reg started_slot,
    output reg [TOKEN_BITS-1:0] started_token,
    input wire video_sof,video_scene_valid,
    input wire [TOKEN_BITS-1:0] video_scene_token,
    output wire scene_start,scene_slot,scene_has_audio,
    output wire [TOKEN_BITS-1:0] scene_token,
    input wire scene_accept
);
    wire src_rst,dst_rst;
    reset_sync source_reset(.clk(src_clk),.rst_in(rst),.rst_out(src_rst));
    reset_sync pixel_reset(.clk(dst_clk),.rst_in(rst),.rst_out(dst_rst));
    reg [TOKEN_BITS+1:0] mailbox,received;
    reg busy,request_toggle,ack_toggle,started_toggle,error_toggle,request_seen;
    reg started_seen,error_seen,pixel_armed,pixel_cancel_seen;
    (* async_reg="true" *) reg request_meta,request_sync,ack_meta,ack_sync;
    (* async_reg="true" *) reg started_meta,started_sync,error_meta,error_sync;
    (* async_reg="true" *) reg cancel_meta,cancel_sync,cancelled_meta,cancelled_sync;
    assign arm_ready=!src_rst && !busy && !cancel && !cancelled_sync;
    assign armed=busy && ack_sync==request_toggle && !cancel && !cancelled_sync;
    assign cancel_ack=cancel && cancelled_sync && !busy && !src_rst;
    assign {scene_slot,scene_has_audio,scene_token}=received;
    assign scene_start=pixel_armed && video_sof && video_scene_valid && video_scene_token==scene_token && !cancel_sync && !dst_rst;
    // 每条请求payload保持到started/error或取消回传，两个域不逐bit同步token。
    always @(posedge src_clk)if(arm_valid && arm_ready)mailbox<={arm_slot,arm_has_audio,arm_token};
    always @(posedge dst_clk)if(!dst_rst && !cancel_sync && request_sync!=request_seen)received<=mailbox;
    always @(posedge src_clk or posedge src_rst)begin
        if(src_rst)begin
            busy<=0;request_toggle<=0;ack_meta<=0;ack_sync<=0;started_meta<=0;started_sync<=0;
            error_meta<=0;error_sync<=0;cancelled_meta<=0;cancelled_sync<=0;started_seen<=0;error_seen<=0;
            started<=0;error<=0;started_slot<=0;started_token<=0;
        end else begin
            ack_meta<=ack_toggle;ack_sync<=ack_meta;started_meta<=started_toggle;started_sync<=started_meta;
            error_meta<=error_toggle;error_sync<=error_meta;cancelled_meta<=pixel_cancel_seen;cancelled_sync<=cancelled_meta;
            started<=0;error<=0;
            if(arm_valid && arm_ready)begin busy<=1;request_toggle<=~request_toggle;end
            if(started_sync!=started_seen)begin
                started_seen<=started_sync;
                if(busy)begin started<=1;started_slot<=mailbox[TOKEN_BITS+1];started_token<=mailbox[TOKEN_BITS-1:0];busy<=0;end
            end
            if(error_sync!=error_seen)begin
                error_seen<=error_sync;
                if(busy)begin error<=1;busy<=0;end
            end
            if(cancel && cancelled_sync)busy<=0;
        end
    end
    always @(posedge dst_clk or posedge dst_rst)begin
        if(dst_rst)begin
            request_meta<=0;request_sync<=0;request_seen<=0;ack_toggle<=0;started_toggle<=0;error_toggle<=0;
            cancel_meta<=0;cancel_sync<=0;pixel_armed<=0;pixel_cancel_seen<=0;
        end else begin
            request_meta<=request_toggle;request_sync<=request_meta;cancel_meta<=cancel;cancel_sync<=cancel_meta;
            pixel_cancel_seen<=cancel_sync;
            if(cancel_sync)begin pixel_armed<=0;request_seen<=request_sync;ack_toggle<=request_sync;end
            else if(request_sync!=request_seen)begin
                request_seen<=request_sync;ack_toggle<=request_sync;pixel_armed<=1;
            end else if(scene_start)begin
                pixel_armed<=0;
                if(scene_accept)started_toggle<=~started_toggle;else error_toggle<=~error_toggle;
            end
        end
    end
endmodule
