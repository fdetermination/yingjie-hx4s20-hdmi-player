`timescale 1ns/1ps
// Ordered commands and a cancel barrier keep queued writes out of later frames.
module frame_write_cdc #(
    parameter integer FIFO_BITS=5
)(
    input wire src_clk,dst_clk,rst,
    input wire src_begin_req,src_bank,
    input wire [7:0] src_token,
    output wire src_begin_accept,
    input wire src_write_valid,
    input wire [20:0] src_write_address,
    input wire [31:0] src_write_data,
    output wire src_write_ready,
    input wire src_flush_req,src_cancel,
    output wire src_flush_ack,src_cancel_ack,src_error,
    output wire [7:0] src_response_token,
    output wire dst_begin_req,dst_bank,
    output wire [7:0] dst_token,
    input wire dst_begin_accept,
    output wire dst_write_valid,
    output wire [20:0] dst_write_address,
    output wire [31:0] dst_write_data,
    input wire dst_write_ready,
    output wire dst_flush_req,dst_cancel,
    input wire dst_flush_ack,dst_cancel_ack,dst_error
);
    localparam BEGIN_CMD=2'd0,WRITE_CMD=2'd1,FLUSH_CMD=2'd2,CANCEL_CMD=2'd3;
    localparam IDLE=0,BEGIN_WAIT=1,ACTIVE=2,FLUSH_WAIT=3,FLUSH_DONE=4,
        CANCEL_SEND=5,CANCEL_WAIT=6,CANCEL_DONE=7;
    wire src_rst,dst_rst;
    reset_sync source_reset(.clk(src_clk),.rst_in(rst),.rst_out(src_rst));
    reset_sync destination_reset(.clk(dst_clk),.rst_in(rst),.rst_out(dst_rst));
    reg [2:0] state;
    reg [7:0] token;
    reg begin_seen,flush_seen,error_seen,source_error;
    reg begin_toggle,flush_toggle,cancelled,error_latched,error_toggle,writer_live;
    (* async_reg="true" *) reg begin_meta,begin_sync,flush_meta,flush_sync;
    (* async_reg="true" *) reg cancelled_meta,cancelled_sync,error_meta,error_sync;
    (* async_reg="true" *) reg cancel_meta,cancel_sync;
    wire fifo_ready,fifo_empty,fifo_valid;
    wire [54:0] fifo_data;
    reg [54:0] packet;
    reg packet_valid,fetch_pending,packet_prepared;
    reg [3:0] packet_kind;
    wire [1:0] opcode=packet[54:53];
    wire send_begin=state==IDLE && src_begin_req && !src_cancel && !cancelled_sync;
    wire send_write=state==ACTIVE && src_write_valid && !src_flush_req && !src_cancel;
    wire send_flush=state==ACTIVE && src_flush_req && !src_cancel;
    wire send_cancel=state==CANCEL_SEND;
    wire fifo_write=!src_rst && (send_begin || send_write || send_flush || send_cancel);
    wire [54:0] fifo_input=send_cancel?{CANCEL_CMD,53'd0}:
        send_flush?{FLUSH_CMD,53'd0}:
        send_begin?{BEGIN_CMD,44'd0,src_bank,src_token}:
        {WRITE_CMD,src_write_address,src_write_data};
    wire fifo_read=!dst_rst && !packet_valid && !fetch_pending && !fifo_empty;
    rgb_async_fifo #(.DATA_BITS(55),.ADDR_BITS(FIFO_BITS)) commands(
        .wr_clk(src_clk),.rd_clk(dst_clk),.rst(rst),.wr_valid(fifo_write),.wr_data(fifo_input),
        .wr_ready(fifo_ready),.wr_used(),.rd_en(fifo_read),.rd_empty(fifo_empty),
        .rd_valid(fifo_valid),.rd_data(fifo_data),.rd_used());
    assign src_begin_accept=!src_rst && !src_cancel && state==ACTIVE && src_begin_req;
    assign src_write_ready=!src_rst && state==ACTIVE && !src_cancel && !src_flush_req && fifo_ready;
    assign src_flush_ack=!src_rst && !src_cancel && state==FLUSH_DONE;
    assign src_cancel_ack=!src_rst && src_cancel && state==CANCEL_DONE;
    assign src_error=source_error && (state==BEGIN_WAIT || state==ACTIVE || state==FLUSH_WAIT) && !src_cancel;
    assign src_response_token=token;
    assign dst_cancel=!dst_rst && (cancel_sync || cancelled || (packet_valid && packet_prepared && packet_kind[3]));
    assign dst_begin_req=packet_valid && packet_prepared && packet_kind[0] && !dst_cancel && !dst_rst;
    assign dst_write_valid=packet_valid && packet_prepared && packet_kind[1] && !dst_cancel && !dst_rst;
    assign dst_flush_req=packet_valid && packet_prepared && packet_kind[2] && !dst_cancel && !dst_rst;
    assign dst_bank=packet[8];assign dst_token=packet[7:0];
    assign dst_write_address=packet[52:32];assign dst_write_data=packet[31:0];
    always @(posedge src_clk or posedge src_rst)begin
        if(src_rst)begin
            state<=IDLE;token<=0;begin_seen<=0;flush_seen<=0;error_seen<=0;source_error<=0;
            begin_meta<=0;begin_sync<=0;flush_meta<=0;flush_sync<=0;
            cancelled_meta<=0;cancelled_sync<=0;error_meta<=0;error_sync<=0;
        end else begin
            begin_meta<=begin_toggle;begin_sync<=begin_meta;begin_seen<=begin_sync;
            flush_meta<=flush_toggle;flush_sync<=flush_meta;flush_seen<=flush_sync;
            cancelled_meta<=cancelled;cancelled_sync<=cancelled_meta;
            error_meta<=error_toggle;error_sync<=error_meta;error_seen<=error_sync;
            if(error_sync!=error_seen && (state==BEGIN_WAIT || state==ACTIVE || state==FLUSH_WAIT))source_error<=1;
            if(src_cancel && state!=CANCEL_SEND && state!=CANCEL_WAIT && state!=CANCEL_DONE)
                state<=CANCEL_SEND;
            else case(state)
                IDLE:if(send_begin && fifo_ready)begin token<=src_token;source_error<=0;state<=BEGIN_WAIT;end
                BEGIN_WAIT:if(begin_sync!=begin_seen)state<=ACTIVE;
                ACTIVE:if(send_flush && fifo_ready)state<=FLUSH_WAIT;
                FLUSH_WAIT:if(flush_sync!=flush_seen)state<=FLUSH_DONE;
                FLUSH_DONE:if(!src_flush_req)state<=IDLE;
                CANCEL_SEND:if(fifo_ready)state<=CANCEL_WAIT;
                CANCEL_WAIT:if(cancelled_sync)state<=CANCEL_DONE;
                CANCEL_DONE:if(!src_cancel)state<=IDLE;
            endcase
        end
    end
    always @(posedge dst_clk)if(fifo_valid)packet<=fifo_data;
    always @(posedge dst_clk or posedge dst_rst)begin
        if(dst_rst)begin
            packet_valid<=0;fetch_pending<=0;packet_prepared<=0;packet_kind<=0;begin_toggle<=0;flush_toggle<=0;
            cancel_meta<=0;cancel_sync<=0;cancelled<=0;error_latched<=0;error_toggle<=0;writer_live<=0;
        end else begin
            cancel_meta<=src_cancel;cancel_sync<=cancel_meta;
            if(fifo_read)fetch_pending<=1;
            if(fifo_valid)begin packet_valid<=1;fetch_pending<=0;packet_prepared<=0;end
            // Decode a stable packet before its type drives frame arbitration.
            if(packet_valid && !packet_prepared)begin
                packet_kind<=4'b0001<<opcode;packet_prepared<=1;
            end
            if(writer_live && dst_error && !error_latched)begin error_latched<=1;error_toggle<=~error_toggle;end
            if(cancelled && !cancel_sync)cancelled<=0;
            if(packet_valid && packet_prepared)begin
                // Cancel drains stale commands even when a failed writer cannot accept data.
                if(dst_cancel)begin
                    writer_live<=0;
                    if(!packet_kind[3])packet_valid<=0;
                    else if(dst_cancel_ack)begin cancelled<=1;packet_valid<=0;end
                end else case(packet_kind)
                    4'b0001:if(dst_begin_accept)begin
                        packet_valid<=0;begin_toggle<=~begin_toggle;writer_live<=1;error_latched<=0;
                    end
                    4'b0010:if(dst_write_ready)packet_valid<=0;
                    4'b0100:if(dst_flush_ack)begin
                        packet_valid<=0;flush_toggle<=~flush_toggle;writer_live<=0;
                    end
                endcase
            end
        end
    end
endmodule
