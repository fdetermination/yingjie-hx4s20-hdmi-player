`timescale 1ns/1ps
// 曲目队列：PCM与EOF标记经过同一个异步FIFO，EOF必须排在最后样本之后。
// clear保持期间同时清空两域；自然source_done只结束供数，不能清空播放尾部。
module pcm_track_stream #(
    parameter integer CLK_HZ=74250000,SAMPLE_HZ=48000,FIFO_BITS=10,
    parameter integer PRELOAD_SAMPLES=128
)(
    input wire wr_clk,clk,rst,clear,
    input wire pcm_valid,source_done,
    output wire pcm_ready,
    input wire signed [15:0] pcm_left,pcm_right,
    output wire sample_valid,
    output wire signed [15:0] sample_left,sample_right,
    output wire [31:0] sample_count,
    output reg underflow,track_done
);
    wire queue_reset=rst || clear;
    wire wr_reset,rd_reset,sample_reset,fifo_ready,fifo_empty,fifo_valid;
    wire [32:0] fifo_data;
    wire [FIFO_BITS:0] fifo_used;
    reg eof_pending,eof_written;
    (* async_reg="true" *) reg eof_meta,eof_sync;
    reg pending,held_valid,playing,finished;
    reg [32:0] held_data;
    wire sample_tick;
    wire have_sample=held_valid && !held_data[32];
    wire take_sample=playing && sample_tick && have_sample;
    wire take_eof=held_valid && held_data[32] && !finished;
    wire read_enable=!rd_reset && !finished && !pending && (!held_valid || take_sample) && !fifo_empty;
    wire write_eof=eof_pending && !pcm_valid && !eof_written;
    wire fifo_write=!wr_reset && !eof_written && (pcm_valid || write_eof);
    assign pcm_ready=!wr_reset && !eof_written && fifo_ready;
    reset_sync write_reset(.clk(wr_clk),.rst_in(queue_reset),.rst_out(wr_reset));
    // 仅EOF状态的SR在下降沿释放；数据ready门控继续使用原上升沿wr_reset，保留整周期预算。
    wire eof_reset;
    reset_sync #(.RELEASE_NEGEDGE(1)) eof_state_reset(.clk(wr_clk),.rst_in(queue_reset),.rst_out(eof_reset));
    reset_sync read_reset(.clk(clk),.rst_in(queue_reset),.rst_out(rd_reset));
    reset_sync sampling_reset(.clk(clk),.rst_in(rst),.rst_out(sample_reset));
    rgb_async_fifo #(.DATA_BITS(33),.ADDR_BITS(FIFO_BITS)) queue(
        .wr_clk(wr_clk),.rd_clk(clk),.rst(queue_reset),.wr_valid(fifo_write),.wr_ready(fifo_ready),
        .wr_data(write_eof?{1'b1,32'd0}:{1'b0,pcm_left,pcm_right}),.wr_used(),
        .rd_en(read_enable),.rd_empty(fifo_empty),.rd_valid(fifo_valid),.rd_data(fifo_data),.rd_used(fifo_used));
    // HDMI持续得到精确48kHz样本；曲目间/正常EOF后静音不计作下溢。
    pcm_playback_engine #(.CLK_HZ(CLK_HZ),.SAMPLE_HZ(SAMPLE_HZ)) sampler(
        .clk(clk),.rst(sample_reset),.enable(1'b1),.pcm_ready(sample_tick),.pcm_valid(1'b1),
        .pcm_left(playing && have_sample?held_data[31:16]:16'd0),
        .pcm_right(playing && have_sample?held_data[15:0]:16'd0),
        .sample_valid(sample_valid),.sample_left(sample_left),.sample_right(sample_right),
        .sample_count(sample_count),.underflow());
    always @(posedge wr_clk or posedge eof_reset)begin
        if(eof_reset)begin eof_pending<=0;eof_written<=0;end
        else begin
            if(source_done)eof_pending<=1;
            if(fifo_write && fifo_ready && write_eof)begin eof_written<=1;eof_pending<=0;end
        end
    end
    always @(posedge clk or posedge rd_reset)begin
        if(rd_reset)begin
            eof_meta<=0;eof_sync<=0;pending<=0;held_valid<=0;held_data<=0;
            playing<=0;finished<=0;underflow<=0;track_done<=0;
        end else begin
            eof_meta<=eof_written;eof_sync<=eof_meta;track_done<=0;
            if(!playing && !finished && have_sample && (fifo_used>=PRELOAD_SAMPLES-1 || eof_sync))playing<=1;
            if(take_sample)held_valid<=0;
            if(read_enable)pending<=1;
            if(fifo_valid)begin held_valid<=1;held_data<=fifo_data;pending<=0;end
            if(take_eof)begin held_valid<=0;playing<=0;finished<=1;track_done<=1;end
            if(playing && sample_tick && !held_valid)underflow<=1;
        end
    end
endmodule
