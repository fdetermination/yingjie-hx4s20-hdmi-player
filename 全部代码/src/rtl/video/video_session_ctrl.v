`timescale 1ns/1ps
// 存储域只凭scanout停止应答解锁；commit_pending端口接manager的重配请求而非应用整段COMMIT。
module video_session_ctrl #(
    parameter integer TOKEN_BITS=8
)(
    input wire clk,pixel_clk,rst,display_valid,commit_pending,display_cancel,
    input wire [TOKEN_BITS-1:0] display_epoch,
    input wire pixel_frame_boundary,start_ready,stop_ack,
    output reg start,stop,
    output wire drained,frame_boundary
);
    reg running;
    reg [TOKEN_BITS-1:0] seen_epoch;
    wire pixel_rst;
    reg boundary_toggle,boundary_seen;
    (* async_reg="true" *) reg boundary_meta,boundary_sync;
    reset_sync pixel_reset(.clk(pixel_clk),.rst_in(rst),.rst_out(pixel_rst));
    assign frame_boundary=boundary_sync!=boundary_seen;
    assign drained=!running && !start && (start_ready || stop_ack);
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)boundary_toggle<=0;
        else if(pixel_frame_boundary)boundary_toggle<=~boundary_toggle;
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            running<=0;start<=0;stop<=0;seen_epoch<=0;
            boundary_meta<=0;boundary_sync<=0;boundary_seen<=0;
        end else begin
            boundary_meta<=boundary_toggle;boundary_sync<=boundary_meta;boundary_seen<=boundary_sync;
            start<=0;
            if((commit_pending || display_cancel) && running)stop<=1;
            if(stop_ack)begin stop<=0;running<=0;end
            if(display_valid && display_epoch!=seen_epoch && !commit_pending && !display_cancel &&
               !running && !stop && start_ready)begin
                start<=1;running<=1;seen_epoch<=display_epoch;
            end
        end
    end
endmodule
