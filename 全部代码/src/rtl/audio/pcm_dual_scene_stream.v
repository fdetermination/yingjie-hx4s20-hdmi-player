`timescale 1ns/1ps
// 两个曲目槽共用持续48kHz采样器，场景在像素域提交。
module pcm_dual_scene_stream #(
    parameter integer CLK_HZ=74250000,SAMPLE_HZ=48000,FIFO_BITS=9,TOKEN_BITS=8,
    parameter integer PRELOAD_SAMPLES=128,READ_RESERVE=130
)(
    input wire wr_clk,clk,rst,
    input wire [1:0] clear,prepare_valid,prepare_has_audio,pcm_valid,source_done,
    input wire [2*TOKEN_BITS-1:0] prepare_token,
    input wire [31:0] pcm_left,pcm_right,
    output wire [1:0] clear_ack,slot_ready,prepare_ready,prepared,pcm_ready,read_room,low_water,
    output wire [2*(FIFO_BITS+1)-1:0] wr_used,
    input wire scene_start,scene_slot,scene_has_audio,
    input wire [TOKEN_BITS-1:0] scene_token,
    output wire scene_accept,
    output reg scene_error,active,active_slot,
    output reg [TOKEN_BITS-1:0] active_token,
    output wire sample_valid,
    output wire signed [15:0] sample_left,sample_right,
    output wire [31:0] sample_count,
    output wire underflow,
    output wire [1:0] slot_underflow,track_done
);
    wire sampler_reset,sample_tick;
    wire [1:0] prepared_pixel,generation_valid,has_audio,head_valid;
    wire [2*TOKEN_BITS-1:0] bound_token;
    wire [31:0] head_left,head_right;
    reset_sync sampling_reset(.clk(clk),.rst_in(rst),.rst_out(sampler_reset));
    assign scene_accept=scene_start && !sampler_reset && prepared_pixel[scene_slot] &&
        bound_token[scene_slot*TOKEN_BITS+:TOKEN_BITS]==scene_token && has_audio[scene_slot]==scene_has_audio;
    genvar slot;
    generate for(slot=0;slot<2;slot=slot+1)begin:slots
        pcm_scene_queue #(.FIFO_BITS(FIFO_BITS),.TOKEN_BITS(TOKEN_BITS),.PRELOAD_SAMPLES(PRELOAD_SAMPLES),.READ_RESERVE(READ_RESERVE)) track(
            .wr_clk(wr_clk),.clk(clk),.rst(rst),.clear(clear[slot]),.clear_ack(clear_ack[slot]),.slot_ready(slot_ready[slot]),
            .prepare_valid(prepare_valid[slot]),.prepare_has_audio(prepare_has_audio[slot]),.prepare_token(prepare_token[slot*TOKEN_BITS+:TOKEN_BITS]),
            .prepare_ready(prepare_ready[slot]),.prepared_mem(prepared[slot]),.pcm_valid(pcm_valid[slot]),.source_done(source_done[slot]),
            .pcm_left(pcm_left[slot*16+:16]),.pcm_right(pcm_right[slot*16+:16]),.pcm_ready(pcm_ready[slot]),
            .read_room(read_room[slot]),.low_water(low_water[slot]),.wr_used(wr_used[slot*(FIFO_BITS+1)+:FIFO_BITS+1]),
            .selected(active && active_slot==slot),.sample_tick(sample_tick),.claim(scene_accept && scene_slot==slot),
            .prepared_pixel(prepared_pixel[slot]),.generation_valid(generation_valid[slot]),.has_audio(has_audio[slot]),
            .bound_token(bound_token[slot*TOKEN_BITS+:TOKEN_BITS]),.head_valid(head_valid[slot]),
            .head_left(head_left[slot*16+:16]),.head_right(head_right[slot*16+:16]),.underflow(slot_underflow[slot]),.track_done(track_done[slot]));
    end endgenerate
    wire consume=active && head_valid[active_slot];
    pcm_playback_engine #(.CLK_HZ(CLK_HZ),.SAMPLE_HZ(SAMPLE_HZ)) sampler(
        .clk(clk),.rst(sampler_reset),.enable(1'b1),.pcm_valid(1'b1),.pcm_ready(sample_tick),
        .pcm_left(consume?head_left[active_slot*16+:16]:16'd0),.pcm_right(consume?head_right[active_slot*16+:16]:16'd0),
        .sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),.sample_count(sample_count),.underflow());
    assign underflow=active && slot_underflow[active_slot];
    always @(posedge clk or posedge sampler_reset)begin
        if(sampler_reset)begin scene_error<=0;active<=0;active_slot<=0;active_token<=0;end
        else begin
            scene_error<=scene_start && !scene_accept;
            if(active && (!generation_valid[active_slot] || track_done[active_slot]))active<=0;
            // 同沿tick仍使用旧active选择；下一tick才消费新曲第0帧，采样相位不变。
            if(scene_accept)begin active<=scene_has_audio;active_slot<=scene_slot;active_token<=scene_token;end
        end
    end
endmodule
