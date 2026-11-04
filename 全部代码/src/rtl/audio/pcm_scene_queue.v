`timescale 1ns/1ps
// 单曲目槽：准备token、PCM/EOF、独立清空握手；采样节拍由共享采样器提供。
module pcm_scene_queue #(
    parameter integer FIFO_BITS=9,TOKEN_BITS=8,PRELOAD_SAMPLES=128,READ_RESERVE=130
)(
    input wire wr_clk,clk,rst,clear,
    output wire clear_ack,slot_ready,
    input wire prepare_valid,prepare_has_audio,
    input wire [TOKEN_BITS-1:0] prepare_token,
    output wire prepare_ready,prepared_mem,
    input wire pcm_valid,source_done,
    input wire signed [15:0] pcm_left,pcm_right,
    output wire pcm_ready,read_room,low_water,
    output wire [FIFO_BITS:0] wr_used,
    input wire selected,sample_tick,claim,
    output wire prepared_pixel,generation_valid,has_audio,head_valid,
    output wire [TOKEN_BITS-1:0] bound_token,
    output wire signed [15:0] head_left,head_right,
    output reg underflow,track_done
);
    localparam DEPTH=1<<FIFO_BITS;
    wire queue_reset=rst || clear;
    wire wr_reset,rd_reset,eof_reset,control_wr_reset,control_rd_reset;
    reset_sync write_reset(.clk(wr_clk),.rst_in(queue_reset),.rst_out(wr_reset));
    reset_sync read_reset(.clk(clk),.rst_in(queue_reset),.rst_out(rd_reset));
    reset_sync #(.RELEASE_NEGEDGE(1)) eof_state_reset(.clk(wr_clk),.rst_in(queue_reset),.rst_out(eof_reset));
    reset_sync control_write_reset(.clk(wr_clk),.rst_in(rst),.rst_out(control_wr_reset));
    reset_sync control_read_reset(.clk(clk),.rst_in(rst),.rst_out(control_rd_reset));
    reg clear_seen,read_released;
    (* async_reg="true" *) reg clear_meta,clear_sync,released_meta,released_sync;
    always @(posedge clk or posedge control_rd_reset)begin
        if(control_rd_reset)begin clear_seen<=0;read_released<=0;end
        else begin clear_seen<=rd_reset;read_released<=!rd_reset;end
    end
    always @(posedge wr_clk or posedge control_wr_reset)begin
        if(control_wr_reset)begin clear_meta<=0;clear_sync<=0;released_meta<=0;released_sync<=0;end
        else begin clear_meta<=clear_seen;clear_sync<=clear_meta;released_meta<=read_released;released_sync<=released_meta;end
    end
    assign clear_ack=clear && clear_sync && !control_wr_reset;
    assign slot_ready=!wr_reset && !clear && !clear_sync && released_sync;

    reg prepare_sent,source_has_audio;
    reg [TOKEN_BITS-1:0] token_mailbox;
    reg [TOKEN_BITS-1:0] token_received;
    reg generation_loaded,received_has_audio,prepared_latched,claimed;
    (* async_reg="true" *) reg prepare_meta,prepare_sync,generation_meta,generation_sync,prepared_meta,prepared_sync;
    assign prepare_ready=slot_ready && !prepare_sent;
    assign prepared_mem=slot_ready && prepare_sent && generation_sync && prepared_sync;
    // 单次准备payload保持到本槽下一次clear，目标只在同步请求到达后捕获。
    always @(posedge wr_clk)if(prepare_valid && prepare_ready)begin token_mailbox<=prepare_token;source_has_audio<=prepare_has_audio;end
    always @(posedge wr_clk or posedge wr_reset)begin
        if(wr_reset)begin prepare_sent<=0;generation_meta<=0;generation_sync<=0;prepared_meta<=0;prepared_sync<=0;end
        else begin
            generation_meta<=generation_loaded;generation_sync<=generation_meta;
            prepared_meta<=prepared_pixel;prepared_sync<=prepared_meta;
            if(prepare_valid && prepare_ready)prepare_sent<=1;
        end
    end
    always @(posedge clk)if(!rd_reset && prepare_sync && !generation_loaded)begin
        token_received<=token_mailbox;received_has_audio<=source_has_audio;
    end
    assign generation_valid=generation_loaded && !rd_reset;
    assign has_audio=generation_valid && received_has_audio;
    assign bound_token=token_received;
    assign prepared_pixel=generation_valid && prepared_latched && !claimed;

    wire fifo_ready,fifo_empty,fifo_valid;
    wire [32:0] fifo_data;
    wire [FIFO_BITS:0] fifo_used;
    reg eof_pending,eof_written;
    (* async_reg="true" *) reg eof_meta,eof_sync;
    reg pending,held_valid,finished;
    reg [32:0] held_data;
    assign head_valid=generation_valid && received_has_audio && held_valid && !held_data[32] && !finished;
    assign head_left=held_data[31:16];assign head_right=held_data[15:0];
    wire take_sample=selected && sample_tick && head_valid;
    wire take_eof=selected && generation_valid && held_valid && held_data[32] && !finished;
    wire read_enable=generation_valid && received_has_audio && !finished && !pending && (!held_valid || take_sample) && !fifo_empty;
    wire write_enabled=slot_ready && prepare_sent && generation_sync && source_has_audio && !eof_written;
    wire write_eof=eof_pending && !pcm_valid && !eof_written;
    wire fifo_write=write_enabled && (pcm_valid || write_eof);
    assign pcm_ready=write_enabled && fifo_ready;
    assign read_room=write_enabled && !eof_pending && wr_used<=DEPTH-READ_RESERVE;
    assign low_water=write_enabled && wr_used<PRELOAD_SAMPLES;
    rgb_async_fifo #(.DATA_BITS(33),.ADDR_BITS(FIFO_BITS)) queue(
        .wr_clk(wr_clk),.rd_clk(clk),.rst(queue_reset),.wr_valid(fifo_write),.wr_ready(fifo_ready),
        .wr_data(write_eof?{1'b1,32'd0}:{1'b0,pcm_left,pcm_right}),.wr_used(wr_used),
        .rd_en(read_enable),.rd_empty(fifo_empty),.rd_valid(fifo_valid),.rd_data(fifo_data),.rd_used(fifo_used));
    always @(posedge wr_clk or posedge eof_reset)begin
        if(eof_reset)begin eof_pending<=0;eof_written<=0;end
        else begin
            if(source_done && !eof_written && ((prepare_sent && source_has_audio) ||
               (prepare_valid && prepare_ready && prepare_has_audio)))eof_pending<=1;
            if(fifo_write && fifo_ready && write_eof)begin eof_written<=1;eof_pending<=0;end
        end
    end
    // payload不复位/门控，以held_valid判断有效；避免读域使能被打包进RAM写域OCE。
    always @(posedge clk)held_data<=fifo_data;
    always @(posedge clk or posedge rd_reset)begin
        if(rd_reset)begin
            prepare_meta<=0;prepare_sync<=0;generation_loaded<=0;prepared_latched<=0;claimed<=0;
            eof_meta<=0;eof_sync<=0;pending<=0;held_valid<=0;finished<=0;underflow<=0;track_done<=0;
        end else begin
            prepare_meta<=prepare_sent;prepare_sync<=prepare_meta;eof_meta<=eof_written;eof_sync<=eof_meta;track_done<=0;
            if(prepare_sync && !generation_loaded)generation_loaded<=1;
            if(generation_loaded && !claimed &&
               (!received_has_audio || (held_valid && (held_data[32] || fifo_used>=PRELOAD_SAMPLES-1 || eof_sync))))prepared_latched<=1;
            if(claim)begin claimed<=1;prepared_latched<=0;end
            if(take_sample)held_valid<=0;
            if(read_enable)pending<=1;
            if(fifo_valid)begin held_valid<=1;pending<=0;end
            if(take_eof)begin held_valid<=0;finished<=1;track_done<=1;end
            if(selected && sample_tick && generation_valid && received_has_audio && !finished && !held_valid)underflow<=1;
        end
    end
endmodule
