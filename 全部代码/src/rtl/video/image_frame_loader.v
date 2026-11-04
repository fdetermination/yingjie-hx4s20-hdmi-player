`timescale 1ns/1ps
// 文件描述符 -> BMP解析 -> 编译期缩放器 -> 已授权帧bank；成功以mem_flush_ack为边界。
module image_frame_loader #(
    parameter integer OUTPUT_WIDTH=1280,OUTPUT_HEIGHT=720,TOKEN_BITS=8,STEP_OPEN_ENABLE=1,
    parameter integer BILINEAR_ENABLE=0
)(
    input wire clk,rst,
    input wire load_req,
    output wire load_accept,
    input wire [27:0] load_cluster,
    input wire [31:0] load_size,
    input wire file_slot,
    input wire load_bank,
    input wire [TOKEN_BITS-1:0] load_token,
    input wire load_cancel,
    output reg load_cancel_ack,frame_ready,frame_error,
    output reg [TOKEN_BITS-1:0] frame_token,
    output wire busy,
    output reg [3:0] error_code,
    output wire file_cmd_valid,
    input wire file_cmd_ready,
    output wire [2:0] file_cmd_op,
    output wire file_cmd_channel,
    output reg [27:0] file_cmd_cluster,
    output reg [31:0] file_cmd_size,
    input wire file_done,file_error,file_open_complete,
    input wire file_data_valid,
    output wire file_data_ready,
    input wire [7:0] file_data_byte,
    input wire file_last,
    output wire file_abort,
    input wire file_cancel_ack,
    output wire mem_begin_req,
    input wire mem_begin_accept,
    output reg mem_bank,
    output reg [TOKEN_BITS-1:0] mem_token,
    output wire mem_write_valid,
    input wire mem_write_ready,
    output wire [20:0] mem_write_address,
    output wire [31:0] mem_write_data,
    output wire mem_flush_req,
    input wire mem_flush_ack,mem_error,
    input wire [TOKEN_BITS-1:0] mem_response_token,
    output wire mem_cancel,
    input wire mem_cancel_ack
);
    localparam IDLE=0,BEGIN_FRAME=1,OPEN_FILE=2,OPEN_WAIT=3,STREAM=4,
        READ_COMMAND=5,READ_WAIT=6,FLUSH=7,CANCEL=8,CANCEL_DONE=9;
    reg [3:0] state;
    reg decoder_start,scaler_start,scaler_started,eof_seen,open_continue,slot_latched;
    reg file_drained,mem_drained,cancel_is_error;
    wire abort_pipeline=state==CANCEL || state==CANCEL_DONE || load_cancel;
    wire decoded_valid,decoded_ready,decoder_done,decoder_error,header_valid;
    wire [23:0] rgb;wire [15:0] x,y,width,height;wire bottom_up;
    wire decoder_in_ready;
    wire scale_write_valid,scale_done,scale_error;
    wire [20:0] local_address;
    wire [31:0] scale_write_data;
    reg write_pending;
    reg scaler_abort;
    reg [20:0] staged_address;
    reg [31:0] staged_data;
    wire scale_write_ready=!write_pending && !abort_pipeline && state!=IDLE;
    // The loader blocks writes immediately; the scaler can retire one cycle later.
    always @(posedge clk or posedge rst)
        if(rst)scaler_abort<=1;else scaler_abort<=abort_pipeline || state<=OPEN_WAIT;
    assign busy=state!=IDLE;
    assign load_accept=state==IDLE && !load_cancel;
    assign file_cmd_valid=(state==OPEN_FILE || state==READ_COMMAND) && !load_cancel;
    assign file_cmd_op=state==OPEN_FILE?(STEP_OPEN_ENABLE?(open_continue?3'd5:3'd4):3'd2):3'd3;
    assign file_cmd_channel=slot_latched;
    assign file_data_ready=state==READ_WAIT && decoder_in_ready && !load_cancel;
    assign file_abort=state==CANCEL;
    assign mem_begin_req=state==BEGIN_FRAME && !load_cancel;
    assign mem_flush_req=state==FLUSH && !load_cancel;
    assign mem_cancel=state==CANCEL;
    assign mem_write_valid=write_pending && !abort_pipeline && state!=IDLE;
    assign mem_write_address=staged_address;
    assign mem_write_data=staged_data;
    // 无组合ready反馈的单项暂存。地址计算在接口前寄存，flush必须等待暂存排空。
    always @(posedge clk or posedge rst)begin
        if(rst)begin write_pending<=0;staged_address<=0;staged_data<=0;end
        else if(abort_pipeline || state==IDLE)write_pending<=0;
        else if(scale_write_valid && scale_write_ready)begin
            write_pending<=1;staged_address<=local_address+(mem_bank?OUTPUT_WIDTH*OUTPUT_HEIGHT:0);
            staged_data<=scale_write_data;
        end else if(mem_write_valid && mem_write_ready)write_pending<=0;
    end
    bmp_stream_decoder decoder(.clk(clk),.rst(rst),.start(decoder_start),.abort(abort_pipeline || state<=OPEN_WAIT),
        .file_size(file_cmd_size),.in_valid(file_data_valid && state==READ_WAIT && !load_cancel),
        .in_ready(decoder_in_ready),.in_data(file_data_byte),.in_last(file_last),
        .pixel_valid(decoded_valid),.pixel_ready(decoded_ready),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),
        .width(width),.height(height),.bottom_up(bottom_up),.header_valid(header_valid),
        .done(decoder_done),.error(decoder_error));
    generate if(BILINEAR_ENABLE)begin:bilinear_path
        bilinear_frame_scaler #(.OUTPUT_WIDTH(OUTPUT_WIDTH),.OUTPUT_HEIGHT(OUTPUT_HEIGHT)) scaler(
            .clk(clk),.rst(rst),.start(scaler_start),.abort(scaler_abort),
            .source_width(width),.source_height(height),.bottom_up(bottom_up),.source_done(decoder_done),
            .pixel_valid(decoded_valid),.pixel_ready(decoded_ready),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),
            .write_valid(scale_write_valid),.write_ready(scale_write_ready),
            .write_address(local_address),.write_data(scale_write_data),.done(scale_done),.error(scale_error),.busy(),.error_code());
    end else begin:nearest_path
        nearest_frame_scaler #(.OUTPUT_WIDTH(OUTPUT_WIDTH),.OUTPUT_HEIGHT(OUTPUT_HEIGHT)) scaler(
        .clk(clk),.rst(rst),.start(scaler_start),.abort(scaler_abort),
        .source_width(width),.source_height(height),.bottom_up(bottom_up),.source_done(decoder_done),
        .pixel_valid(decoded_valid),.pixel_ready(decoded_ready),.pixel_rgb(rgb),.pixel_x(x),.pixel_y(y),
        .write_valid(scale_write_valid),.write_ready(scale_write_ready),
        .write_address(local_address),.write_data(scale_write_data),.done(scale_done),.error(scale_error),.busy(),.error_code());
    end endgenerate
    task cancel_transaction(input [3:0] code);
        begin state<=CANCEL;file_drained<=0;mem_drained<=0;cancel_is_error<=1;error_code<=code;end
    endtask
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;decoder_start<=0;scaler_start<=0;scaler_started<=0;eof_seen<=0;open_continue<=0;slot_latched<=0;
            file_drained<=0;mem_drained<=0;cancel_is_error<=0;
            load_cancel_ack<=0;frame_ready<=0;frame_error<=0;frame_token<=0;error_code<=0;
            file_cmd_cluster<=0;file_cmd_size<=0;mem_bank<=0;mem_token<=0;
        end else begin
            decoder_start<=0;scaler_start<=0;frame_ready<=0;frame_error<=0;
            if(state!=CANCEL_DONE)load_cancel_ack<=0;
            if(state!=IDLE && state!=CANCEL && state!=CANCEL_DONE && load_cancel)begin
                state<=CANCEL;file_drained<=0;mem_drained<=0;cancel_is_error<=0;
            end else if(state!=IDLE && state!=CANCEL && state!=CANCEL_DONE &&
                        mem_error && mem_response_token==mem_token)cancel_transaction(3);
            else if(scaler_started && state!=CANCEL && state!=CANCEL_DONE && scale_error)cancel_transaction(2);
            else if(state>=STREAM && state<=FLUSH && decoder_error)cancel_transaction(1);
            else begin
                if(header_valid && !scaler_started && state>=STREAM && state<=READ_WAIT)begin scaler_start<=1;scaler_started<=1;end
                if(file_data_valid && file_data_ready && file_last)eof_seen<=1;
                case(state)
                    IDLE:if(load_req && load_accept)begin
                        file_cmd_cluster<=load_cluster;file_cmd_size<=load_size;mem_bank<=load_bank;mem_token<=load_token;
                        open_continue<=0;slot_latched<=file_slot;
                        frame_token<=load_token;state<=BEGIN_FRAME;error_code<=0;scaler_started<=0;eof_seen<=0;
                    end else if(load_cancel)load_cancel_ack<=1;
                    BEGIN_FRAME:if(mem_begin_accept)state<=OPEN_FILE;
                    OPEN_FILE:if(file_cmd_ready)state<=OPEN_WAIT;
                    OPEN_WAIT:if(file_error)cancel_transaction(4);
                              else if(file_done)begin
                                  if(!STEP_OPEN_ENABLE || file_open_complete)begin decoder_start<=1;state<=STREAM;end
                                  else begin open_continue<=1;state<=OPEN_FILE;end
                              end
                    STREAM:if(decoder_done && scale_done && eof_seen && !write_pending)state<=FLUSH;
                           else if(!eof_seen)state<=READ_COMMAND;
                    READ_COMMAND:if(file_cmd_ready)state<=READ_WAIT;
                    READ_WAIT:if(file_error)cancel_transaction(4);else if(file_done)state<=STREAM;
                    FLUSH:if(mem_flush_ack && mem_response_token==mem_token)begin
                        frame_ready<=1;frame_token<=mem_token;state<=IDLE;
                    end
                    CANCEL:begin
                        if(file_cancel_ack)file_drained<=1;
                        if(mem_cancel_ack)mem_drained<=1;
                        if((file_drained || file_cancel_ack) && (mem_drained || mem_cancel_ack))begin
                            state<=CANCEL_DONE;load_cancel_ack<=1;
                            if(cancel_is_error)begin frame_error<=1;frame_token<=mem_token;end
                        end
                    end
                    CANCEL_DONE:if(!load_cancel)begin state<=IDLE;load_cancel_ack<=0;end
                endcase
            end
        end
    end
endmodule
