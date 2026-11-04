`timescale 1ns/1ps
// A held start descriptor and an acknowledged stop own the physical read locks.
module video_session_cdc(
    input wire src_clk,dst_clk,rst,
    input wire src_start,src_stop,src_dual,src_bank,src_next_bank,
    input wire [7:0] src_scene_token,
    output wire src_start_ready,src_stop_ack,
    output wire src_error,src_underflow,src_transition_done,
    output wire dst_start,dst_stop,dst_dual,dst_bank,dst_next_bank,
    output wire [7:0] dst_scene_token,
    output reg [1:0] dst_locks,
    input wire dst_start_ready,dst_stop_ack,dst_error,dst_underflow,dst_transition_done
);
    wire src_rst,dst_rst;
    reset_sync source_reset(.clk(src_clk),.rst_in(rst),.rst_out(src_rst));
    reset_sync destination_reset(.clk(dst_clk),.rst_in(rst),.rst_out(dst_rst));
    reg [10:0] mailbox,received;
    reg request_toggle,request_seen,ack_toggle,running,pending,stopped;
    (* async_reg="true" *) reg request_meta,request_sync,stop_meta,stop_sync;
    (* async_reg="true" *) reg ack_meta,ack_sync,stopped_meta,stopped_sync;
    (* async_reg="true" *) reg error_meta,error_sync,underflow_meta,underflow_sync,transition_meta,transition_sync;
    assign src_start_ready=!src_rst && !running && !src_stop && !stopped_sync && request_toggle==ack_sync;
    assign src_stop_ack=!src_rst && src_stop && stopped_sync && request_toggle==ack_sync;
    assign src_error=error_sync;assign src_underflow=underflow_sync;assign src_transition_done=transition_sync;
    assign {dst_dual,dst_bank,dst_next_bank,dst_scene_token}=received;
    assign dst_start=!dst_rst && pending && dst_start_ready && !stop_sync;
    assign dst_stop=!dst_rst && stop_sync;
    always @(posedge src_clk)if(src_start && src_start_ready)
        mailbox<={src_dual,src_bank,src_next_bank,src_scene_token};
    always @(posedge dst_clk)if(!dst_rst && !stop_sync && request_sync!=request_seen)received<=mailbox;
    always @(posedge src_clk or posedge src_rst)begin
        if(src_rst)begin
            request_toggle<=0;running<=0;ack_meta<=0;ack_sync<=0;stopped_meta<=0;stopped_sync<=0;
            error_meta<=0;error_sync<=0;underflow_meta<=0;underflow_sync<=0;transition_meta<=0;transition_sync<=0;
        end else begin
            ack_meta<=ack_toggle;ack_sync<=ack_meta;stopped_meta<=stopped;stopped_sync<=stopped_meta;
            error_meta<=dst_error;error_sync<=error_meta;underflow_meta<=dst_underflow;underflow_sync<=underflow_meta;
            transition_meta<=dst_transition_done;transition_sync<=transition_meta;
            if(src_start && src_start_ready)begin request_toggle<=~request_toggle;running<=1;end
            if(src_stop_ack)running<=0;
        end
    end
    always @(posedge dst_clk or posedge dst_rst)begin
        if(dst_rst)begin
            request_meta<=0;request_sync<=0;request_seen<=0;ack_toggle<=0;stop_meta<=0;stop_sync<=0;
            pending<=0;stopped<=0;dst_locks<=0;
        end else begin
            request_meta<=request_toggle;request_sync<=request_meta;stop_meta<=src_stop;stop_sync<=stop_meta;
            if(stop_sync)begin
                pending<=0;request_seen<=request_sync;ack_toggle<=request_sync;
                if(dst_stop_ack && request_sync==request_seen && !pending)begin stopped<=1;dst_locks<=0;end
            end else begin
                stopped<=0;
                if(request_sync!=request_seen)begin request_seen<=request_sync;pending<=1;end
                if(dst_start)begin
                    pending<=0;ack_toggle<=request_seen;
                    dst_locks<=dst_dual?2'b11:(dst_bank?2'b10:2'b01);
                end
            end
        end
    end
endmodule
