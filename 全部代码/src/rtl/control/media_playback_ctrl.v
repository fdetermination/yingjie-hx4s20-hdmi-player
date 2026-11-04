`timescale 1ns/1ps
// 映界自主播放调度：资源准备与显示提交解耦，事务 token 防止迟到响应。
// 所有输入都已同步到 clk；commit_accept 由显示端安全切换后返回。
module media_playback_ctrl #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer MAX_IMAGES=4,
    parameter integer INDEX_BITS=(MAX_IMAGES<2)?1:$clog2(MAX_IMAGES),
    parameter integer TOKEN_BITS=8,
    parameter integer REQUEST_TIMEOUT_CYCLES=CLK_FREQ_HZ,
    parameter integer LOAD_TIMEOUT_CYCLES=CLK_FREQ_HZ*10,
    parameter integer COMMIT_TIMEOUT_CYCLES=CLK_FREQ_HZ*2
)(
    input wire clk, rst, restart,
    input wire scan_done, scan_error,
    output wire scan_ready,
    input wire [INDEX_BITS:0] image_count,
    input wire key_next, key_auto,
    input wire [1:0] interval_sel,
    output wire load_req,
    input wire load_accept,
    output reg [INDEX_BITS-1:0] load_index,
    output reg load_buffer,
    output reg [TOKEN_BITS-1:0] load_token,
    output reg load_cancel,
    output reg cancel_flush_display,
    input wire cancel_ack,
    input wire frame_ready, frame_error,
    input wire [TOKEN_BITS-1:0] frame_token,
    output wire commit_req,
    input wire commit_accept,
    input wire [TOKEN_BITS-1:0] commit_token,
    output reg display_commit, display_valid,
    output reg [INDEX_BITS-1:0] display_index,
    output reg display_buffer, auto_play_en,
    output reg [2:0] interval_sec,
    output reg [3:0] error_code,
    output wire busy
);
    localparam [2:0] WAIT_SCAN=0, REQUEST=1, LOADING=2, COMMIT=3, PLAYING=4, FAILED=5, CANCEL=6, REFLUSH=7;
    reg [2:0] state;
    reg [INDEX_BITS:0] count;
    reg pending_next;
    reg rescan_after_cancel;
    reg [31:0] watchdog, subsecond;
    reg [2:0] seconds;
    wire [2:0] selected_interval=(interval_sel==1)?3:((interval_sel==2)?5:1);
    wire interval_change=selected_interval!=interval_sec;
    wire auto_due=auto_play_en && !key_auto && !interval_change &&
                  subsecond==CLK_FREQ_HZ-1 && seconds>=interval_sec-1;
    wire completion_matches=frame_token==load_token;
    assign load_req=state==REQUEST;
    assign scan_ready=state==WAIT_SCAN && !restart && !rst;
    assign commit_req=state==COMMIT;
    assign busy=load_req || state==LOADING || commit_req || state==CANCEL || state==REFLUSH;

    function [INDEX_BITS-1:0] following;
        input [INDEX_BITS-1:0] current;
        begin following=({1'b0,current}+1>=count)?0:current+1'b1; end
    endfunction

    // 事务请求始终指向当前不被显示端占有的 bank。
    task request_image;
        input [INDEX_BITS-1:0] index;
        begin
            load_index<=index;
            load_buffer<=display_valid ? ~display_buffer : 1'b0;
            load_token<=load_token+1'b1;
            watchdog<=0; subsecond<=0; seconds<=0;
            state<=REQUEST;
        end
    endtask
    task fail_transaction;
        input [3:0] code;
        begin
            state<=CANCEL; error_code<=code; load_cancel<=1;
            cancel_flush_display<=state==COMMIT; rescan_after_cancel<=0;
            pending_next<=0; auto_play_en<=0; watchdog<=0;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=WAIT_SCAN; count<=0; pending_next<=0; watchdog<=0;
            subsecond<=0; seconds<=0; load_index<=0; load_buffer<=0;
            load_token<=0; load_cancel<=0; display_commit<=0; display_valid<=0;
            cancel_flush_display<=0; rescan_after_cancel<=0;
            display_index<=0; display_buffer<=0; auto_play_en<=0;
            interval_sec<=1; error_code<=0;
        end else begin
            if(state!=CANCEL) load_cancel<=0;
            display_commit<=0; interval_sec<=selected_interval;
            if(restart && state!=CANCEL && state!=REFLUSH) begin
                state<=(busy || display_valid)?CANCEL:WAIT_SCAN;
                count<=0; pending_next<=0; watchdog<=0;
                subsecond<=0; seconds<=0; auto_play_en<=0; display_valid<=0;
                display_index<=0; display_buffer<=0; error_code<=0;
                load_cancel<=busy || display_valid;
                cancel_flush_display<=busy || display_valid; rescan_after_cancel<=1;
            end else begin
                if(key_auto && count>1 && state!=FAILED && state!=CANCEL && state!=REFLUSH)
                    auto_play_en<=~auto_play_en;
                if(busy && key_next) pending_next<=1;
                if(state!=PLAYING || !auto_play_en || key_auto || interval_change || key_next) begin
                    subsecond<=0; seconds<=0;
                end else if(subsecond==CLK_FREQ_HZ-1) begin
                    subsecond<=0; seconds<=seconds+1'b1;
                end else subsecond<=subsecond+1'b1;

                case(state)
                    WAIT_SCAN: if(scan_error) begin
                        count<=0; error_code<=6; state<=FAILED; auto_play_en<=0;
                    end else if(scan_done) begin
                        count<=(image_count>MAX_IMAGES)?MAX_IMAGES:image_count;
                        if(image_count==0) begin error_code<=1; state<=FAILED; end
                        else request_image(0);
                    end
                    REQUEST: begin
                        if(load_accept) begin state<=LOADING; watchdog<=0; end
                        else if(watchdog>=REQUEST_TIMEOUT_CYCLES-1) fail_transaction(3);
                        else watchdog<=watchdog+1'b1;
                    end
                    LOADING: begin
                        if(frame_error && completion_matches) fail_transaction(2);
                        else if(frame_ready && completion_matches) begin state<=COMMIT; watchdog<=0; end
                        else if(watchdog>=LOAD_TIMEOUT_CYCLES-1) fail_transaction(4);
                        else watchdog<=watchdog+1'b1;
                    end
                    COMMIT: begin
                        if(frame_error && completion_matches) fail_transaction(2);
                        else if(commit_accept && commit_token==load_token) begin
                            display_index<=load_index; display_buffer<=load_buffer;
                            display_valid<=1; display_commit<=1; error_code<=0;
                            pending_next<=pending_next || key_next;
                            state<=PLAYING; watchdog<=0; subsecond<=0; seconds<=0;
                        end else if(watchdog>=COMMIT_TIMEOUT_CYCLES-1) fail_transaction(5);
                        else watchdog<=watchdog+1'b1;
                    end
                    PLAYING: if(count>1 && (pending_next || key_next || auto_due)) begin
                        pending_next<=0; request_image(following(display_index));
                    end else pending_next<=0;
                    CANCEL: begin
                        if(restart) begin rescan_after_cancel<=1; pending_next<=0; end
                        if(cancel_ack) begin
                            load_cancel<=0;
                            if(cancel_flush_display) display_valid<=0;
                            if((rescan_after_cancel || restart) && !cancel_flush_display) begin
                                // 原取消只排空加载器；先拉低请求一拍，再单独取消显示。
                                state<=REFLUSH;
                            end else if(rescan_after_cancel || restart) begin
                                state<=WAIT_SCAN; count<=0; pending_next<=0;
                                auto_play_en<=0;
                                error_code<=0; display_index<=0; display_buffer<=0;
                            end else state<=FAILED;
                            cancel_flush_display<=0;
                        end
                    end
                    REFLUSH: begin load_cancel<=1; cancel_flush_display<=1;
                        rescan_after_cancel<=1; state<=CANCEL; end
                    FAILED: if((key_next || pending_next) && count!=0) begin
                        pending_next<=0; request_image(following(load_index));
                    end
                    default: begin state<=WAIT_SCAN; display_valid<=0; auto_play_en<=0; end
                endcase
            end
        end
    end
endmodule
