`timescale 1ns/1ps
// WAV文件播放事务：channel 1打开/读取文件，解析器输出带背压的PCM帧。
// 图像加载使用channel 0；上层仲裁文件命令，abort保持到文件服务确认排空。
module wav_file_player #(
    parameter integer TOKEN_BITS=8,STEP_OPEN_ENABLE=1
)(
    input wire clk,rst,
    input wire start,
    output wire start_ready,
    input wire [27:0] file_cluster,
    input wire [31:0] file_size,
    input wire file_slot,
    input wire abort,
    output wire busy,
    output wire file_idle,
    output reg done,error,cancel_ack,
    output reg [3:0] error_code,
    output wire pcm_valid,
    input wire pcm_ready,
    input wire file_read_allow,
    output wire signed [15:0] pcm_left,pcm_right,
    output wire file_cmd_valid,
    input wire file_cmd_ready,
    output wire [2:0] file_cmd_op,
    output wire file_cmd_channel,
    output wire [27:0] file_cmd_cluster,
    output wire [31:0] file_cmd_size,
    input wire file_done,file_error,file_open_complete,
    output wire file_data_ready,
    input wire file_data_valid,
    input wire [7:0] file_data_byte,
    input wire file_last,
    output wire file_abort,
    input wire file_cancel_ack
);
    localparam IDLE=0,OPEN_CMD=1,OPEN_WAIT=2,READ_CMD=3,READ_WAIT=4,
        CANCEL=5,CANCEL_DONE=6,READ_RESERVE=7;
    reg [2:0] state;
    reg [27:0] cluster_latched;
    reg [31:0] size_latched;
    reg decoder_start,open_continue,slot_latched;
    reg eof_seen,file_done_seen,decoder_done_seen,cancel_is_error;
    wire decoder_pcm_valid,decoder_in_ready,decoder_done,decoder_error;
    wire signed [15:0] decoder_left,decoder_right;
    wire decoder_busy;
    wire [3:0] decoder_error_code;

    assign start_ready=state==IDLE && !rst && !abort;
    assign busy=state!=IDLE;
    assign file_idle=state==IDLE || state==READ_RESERVE;
    assign file_cmd_valid=(state==OPEN_CMD || state==READ_CMD) && !abort;
    assign file_cmd_op=state==OPEN_CMD?(STEP_OPEN_ENABLE?(open_continue?3'd5:3'd4):3'd2):3'd3;
    assign file_cmd_channel=slot_latched;
    assign file_cmd_cluster=cluster_latched;
    assign file_cmd_size=size_latched;
    assign file_data_ready=state==READ_WAIT && !abort && decoder_in_ready;
    assign file_abort=state==CANCEL;
    assign pcm_valid=decoder_pcm_valid && !abort && (state==READ_RESERVE || state==READ_CMD || state==READ_WAIT);
    assign pcm_left=decoder_left;
    assign pcm_right=decoder_right;

    wav_stream_decoder decoder(
        .clk(clk),.rst(rst),.start(decoder_start),.abort(abort || state<=OPEN_WAIT || state==CANCEL || state==CANCEL_DONE),
        .file_size(size_latched),.in_valid(file_data_valid && state==READ_WAIT && !abort),
        .in_ready(decoder_in_ready),.in_data(file_data_byte),.in_last(file_last),
        .pcm_valid(decoder_pcm_valid),.pcm_ready(pcm_ready),.pcm_left(decoder_left),.pcm_right(decoder_right),
        .busy(decoder_busy),.done(decoder_done),.error(decoder_error),.error_code(decoder_error_code));

    task begin_cancel;
        input [3:0] code;
        begin
            state<=CANCEL;cancel_is_error<=1;error<=1;error_code<=code;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;cluster_latched<=0;size_latched<=0;decoder_start<=0;open_continue<=0;slot_latched<=0;
            eof_seen<=0;file_done_seen<=0;decoder_done_seen<=0;cancel_is_error<=0;
            done<=0;error<=0;cancel_ack<=0;error_code<=0;
        end else begin
            decoder_start<=0;done<=0;cancel_ack<=0;
            if(abort && state!=IDLE && state!=CANCEL && state!=CANCEL_DONE) begin
                state<=CANCEL;cancel_is_error<=0;error<=0;error_code<=0;
                eof_seen<=0;file_done_seen<=0;decoder_done_seen<=0;
            end else if((state==READ_RESERVE || state==READ_CMD || state==READ_WAIT) && decoder_error) begin
                begin_cancel(decoder_error_code);
            end else begin
                case(state)
                IDLE: if(abort)cancel_ack<=1;
                else if(start && start_ready) begin
                    cluster_latched<=file_cluster;size_latched<=file_size;slot_latched<=file_slot;open_continue<=0;
                    eof_seen<=0;file_done_seen<=0;decoder_done_seen<=0;cancel_is_error<=0;
                    error<=0;error_code<=0;state<=OPEN_CMD;
                end
                OPEN_CMD: if(file_cmd_ready) state<=OPEN_WAIT;
                OPEN_WAIT: if(file_error) begin_cancel(4);
                           else if(file_done)begin
                               if(!STEP_OPEN_ENABLE || file_open_complete)begin state<=READ_RESERVE;decoder_start<=1;end
                               else begin open_continue<=1;state<=OPEN_CMD;end
                           end
                // 先排空上一块PCM；预留后没有字节输入或其他写者，容量不会减小。
                READ_RESERVE:if(file_read_allow && !decoder_pcm_valid)state<=READ_CMD;
                READ_CMD: begin
                    // 仅READ_WAIT消费该标志；等待命令时预清，避开容量/仲裁组合反馈。
                    file_done_seen<=0;
                    if(file_cmd_valid && file_cmd_ready)state<=READ_WAIT;
                end
                READ_WAIT: begin
                    if(file_error) begin_cancel(5);
                    else begin
                        if(file_data_valid && file_data_ready && file_last)eof_seen<=1;
                        if(file_done)file_done_seen<=1;
                        if(decoder_done)decoder_done_seen<=1;
                        if(file_done && !(eof_seen || (file_data_valid && file_data_ready && file_last)) && !decoder_done)
                            state<=READ_RESERVE;
                        if((decoder_done || decoder_done_seen) && (file_done_seen || file_done) &&
                           (eof_seen || (file_data_valid && file_data_ready && file_last))) begin
                            done<=1;state<=IDLE;
                        end
                    end
                end
                CANCEL: if(file_cancel_ack) begin
                    cancel_ack<=1;state<=CANCEL_DONE;
                    if(cancel_is_error)begin done<=0;end
                end
                CANCEL_DONE: if(!abort) state<=IDLE;
                endcase
            end
        end
    end
endmodule
