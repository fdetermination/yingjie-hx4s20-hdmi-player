`timescale 1ns/1ps
// 显示帧所有权与提交边界：加载器只写未锁bank，显示端只在帧边界切换epoch。
// frame_ready/frame_error为加载端事件；commit_accept与cancel_ack保持到调用方撤销请求。
module video_frame_manager #(
    parameter integer TOKEN_BITS=8,ENABLE_TRANSITION=0
)(
    input wire clk,rst,
    input wire frame_ready,frame_error,
    input wire frame_bank,
    input wire [TOKEN_BITS-1:0] frame_token,
    input wire commit_req,
    output wire commit_accept,
    output wire [TOKEN_BITS-1:0] commit_token,
    input wire cancel_flush_display,
    input wire frame_boundary,
    input wire display_idle,
    input wire fifo0_empty,fifo1_empty,
    input wire transition_done,
    output wire scan_dual,scan_next_bank,session_reconfigure,
    output wire [TOKEN_BITS-1:0] scan_scene_token,
    output wire [1:0] display_locks,
    output reg display_valid,display_bank,
    output reg [TOKEN_BITS-1:0] display_epoch,
    output reg [TOKEN_BITS-1:0] frame_response_token,
    output reg frame_fault,
    output wire cancel_ack
);
    reg pending_valid,pending_bank;
    reg [TOKEN_BITS-1:0] pending_token;
    reg commit_confirmed,cancel_confirmed;
    reg [TOKEN_BITS-1:0] accepted_token;
    reg [TOKEN_BITS-1:0] display_scene_token;
    localparam SINGLE=0,PREPARE=1,MIX=2,FINISH=3;
    reg [1:0] phase;
    wire drained=display_idle && fifo0_empty && fifo1_empty;
    wire new_commit=commit_req && !commit_confirmed && pending_valid && !frame_error && !cancel_flush_display;
    wire commit_start=ENABLE_TRANSITION && new_commit && phase==SINGLE && display_valid;
    assign scan_dual=ENABLE_TRANSITION && (phase==MIX || phase==FINISH);
    assign scan_next_bank=pending_bank;
    assign scan_scene_token=scan_dual?pending_token:display_scene_token;
    assign session_reconfigure=ENABLE_TRANSITION ? (phase==PREPARE || phase==FINISH || commit_start) : commit_req;
    wire commit_safe=new_commit && drained && (ENABLE_TRANSITION ?
        ((!display_valid && phase==SINGLE) || phase==FINISH) : frame_boundary);
    wire cancel_safe=cancel_flush_display && !cancel_confirmed && drained && (ENABLE_TRANSITION || frame_boundary);
    assign commit_accept=(commit_confirmed || commit_safe) && !cancel_flush_display;
    assign commit_token=commit_confirmed?accepted_token:pending_token;
    // 无显示取消时可立即应答；请求上升当拍不能泄漏旧的空闲ack。
    assign cancel_ack=!rst && (!cancel_flush_display || cancel_confirmed);
    assign display_locks=display_valid ? ((ENABLE_TRANSITION && (phase!=SINGLE || commit_start))?
        2'b11:(display_bank?2'b10:2'b01)):2'b00;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            pending_valid<=0;pending_bank<=0;pending_token<=0;commit_confirmed<=0;cancel_confirmed<=0;accepted_token<=0;display_scene_token<=0;
            display_valid<=0;display_bank<=0;display_epoch<=0;frame_response_token<=0;frame_fault<=0;
            phase<=SINGLE;
        end else begin
            if(!commit_req)commit_confirmed<=0;
            if(!cancel_flush_display)cancel_confirmed<=0;
            if(frame_ready && !cancel_flush_display)begin
                pending_valid<=1;pending_bank<=frame_bank;pending_token<=frame_token;
                frame_response_token<=frame_token;frame_fault<=0;
            end
            if(frame_error)begin
                frame_fault<=1;frame_response_token<=frame_token;
                if(frame_token==pending_token)pending_valid<=0;
            end
            if(commit_safe)begin
                display_valid<=1;display_bank<=pending_bank;display_epoch<=display_epoch+1'b1;
                pending_valid<=0;commit_confirmed<=1;accepted_token<=pending_token;
                display_scene_token<=pending_token;
                phase<=SINGLE;
            end
            if(ENABLE_TRANSITION && !cancel_flush_display)begin
                if(commit_start)phase<=PREPARE;
                if(phase==PREPARE && drained && new_commit)begin
                    phase<=MIX;display_epoch<=display_epoch+1'b1;
                end
                if(phase==MIX && transition_done)phase<=FINISH;
            end
            if(cancel_flush_display)begin pending_valid<=0;commit_confirmed<=0;end
            if(cancel_safe)begin
                display_valid<=0;display_epoch<=display_epoch+1'b1;cancel_confirmed<=1;phase<=SINGLE;
            end
        end
    end
endmodule
