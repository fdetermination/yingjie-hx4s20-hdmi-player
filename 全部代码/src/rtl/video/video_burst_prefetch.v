`timescale 1ns/1ps
// 125MHz SDRAM读端预取：每次先为完整burst预留FIFO空间，再接受无背压返回流。
// 两路交替服务，地址按帧内256word边界递增；显示端消费由异步FIFO另一时钟域完成。
module video_burst_prefetch #(
    parameter integer FRAME_WORDS=921600,
    parameter integer FIFO_DEPTH=4096,
    parameter integer BURST_WORDS=256
)(
    input wire clk,rst,start,stop,
    input wire lane0_enable,lane1_enable,
    input wire [20:0] lane0_base,lane1_base,
    input wire [20:0] frame_words,
    input wire [12:0] fifo0_used,fifo1_used,
    input wire fifo0_ready,fifo1_ready,
    output reg fifo0_wr_valid,
    output reg [23:0] fifo0_wr_data,
    output reg fifo1_wr_valid,
    output reg [23:0] fifo1_wr_data,
    output wire read_req,
    input wire read_accept,
    output wire [20:0] read_address,
    output wire [8:0] read_length,
    input wire read_valid,read_last,read_done,read_error,
    input wire [31:0] read_data,
    output reg running,done,error,
    output reg [2:0] error_code,
    output reg active_lane,
    output reg [31:0] burst_count
);
    localparam S_IDLE=0,S_REQUEST=1,S_READ=2,S_FINISH=3,S_PREPARE=4;
    reg [2:0] state;
    reg lane_turn,stop_pending;
    reg [20:0] remaining0,remaining1,next0,next1;
    reg enabled0,enabled1;
    reg [8:0] current_len,current_last,words_seen;
    reg [20:0] current_base;
    reg current_lane;
    reg ahead_valid,ahead_ready,burst_complete;
    reg [20:0] ahead_base;
    reg [8:0] ahead_len,ahead_last;
    // 输出暂存尚未计入FIFO used时，禁止对同lane预订下一burst。
    wire can0=enabled0 && remaining0!=0 && !fifo0_wr_valid && fifo0_used<=FIFO_DEPTH-BURST_WORDS;
    wire can1=enabled1 && remaining1!=0 && !fifo1_wr_valid && fifo1_used<=FIFO_DEPTH-BURST_WORDS;
    wire all_done=(!enabled0 || remaining0==0) && (!enabled1 || remaining1==0);
    wire [20:0] remaining=current_lane?remaining1:remaining0;
    wire [8:0] page_left=9'd256-{1'b0,current_base[7:0]};
    wire [8:0] burst_limit=page_left<BURST_WORDS?page_left:BURST_WORDS;
    wire [8:0] prepared_len=remaining<burst_limit?remaining[8:0]:burst_limit;
    wire transfer_complete=read_valid?(words_seen==current_last && read_last):burst_complete;
    wire beat_fault=read_valid && (words_seen>=current_len || read_last!=(words_seen==current_last) ||
        (current_lane?!fifo1_ready:!fifo0_ready));
    wire completion_fault=!transfer_complete || read_error || error || beat_fault;
    // 仅预计算另一条lane，避免对当前尚未返回的word重复使用FIFO信用。
    wire [20:0] opposite_base=current_lane?next0:next1;
    wire [20:0] opposite_remaining=current_lane?remaining0:remaining1;
    wire [8:0] opposite_page=9'd256-{1'b0,opposite_base[7:0]};
    wire [8:0] opposite_limit=opposite_page<BURST_WORDS?opposite_page:BURST_WORDS;
    wire [8:0] opposite_len=opposite_remaining<opposite_limit?opposite_remaining[8:0]:opposite_limit;
    wire chain_request=state==S_READ && read_done && !read_valid && ahead_ready && burst_complete && !error && !read_error;
    wire promote=chain_request && read_accept && read_req;
    // FIFO输入寄存切开“状态译码→指针加法→满标志”路径，信用按整burst预留。
    always @(posedge clk or posedge rst)begin
        if(rst)begin fifo0_wr_valid<=0;fifo1_wr_valid<=0;fifo0_wr_data<=0;fifo1_wr_data<=0;end
        else begin
            fifo0_wr_valid<=state==S_READ && read_valid && !current_lane && fifo0_ready;
            fifo1_wr_valid<=state==S_READ && read_valid && current_lane && fifo1_ready;
            fifo0_wr_data<=read_data[31:8];fifo1_wr_data<=read_data[31:8];
        end
    end
    assign read_req=(state==S_REQUEST || chain_request) && running && !stop && !stop_pending;
    // S_READ有效请求必用ahead；提前选描述符，避免read_done串接帧范围比较。
    assign read_address=(state==S_READ && ahead_ready)?ahead_base:current_base;
    assign read_length=(state==S_READ && ahead_ready)?ahead_len:current_len;
    always @(posedge clk or posedge rst)begin
        if(rst)words_seen<=0;
        else if(state!=S_READ || read_done)words_seen<=0;
        else if(read_valid)words_seen<=words_seen+1'b1;
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=S_IDLE;lane_turn<=0;remaining0<=0;remaining1<=0;next0<=0;next1<=0;enabled0<=0;enabled1<=0;
            current_len<=0;current_last<=0;ahead_valid<=0;ahead_ready<=0;burst_complete<=0;ahead_base<=0;ahead_len<=0;ahead_last<=0;
            current_base<=0;current_lane<=0;running<=0;done<=0;error<=0;error_code<=0;stop_pending<=0;
            active_lane<=0;burst_count<=0;
        end else begin
            done<=0;
            if(start && !running && state==S_IDLE)begin
                remaining0<=frame_words;remaining1<=frame_words;next0<=lane0_base;next1<=lane1_base;
                enabled0<=lane0_enable;enabled1<=lane1_enable;
                lane_turn<=0;running<=1;stop_pending<=0;error<=0;error_code<=0;burst_count<=0;state<=S_IDLE;
                if(frame_words==0 || frame_words>FRAME_WORDS || (!lane0_enable && !lane1_enable))begin
                    error<=1;error_code<=5;state<=S_FINISH;
                end
            end
            if(stop && running)stop_pending<=1;
            ahead_ready<=ahead_valid;
            if(ahead_valid)ahead_last<=ahead_len-1'b1;
            // 长度已经在PREPARE寄存；在接受命令时预计算末字索引，避免连续减法路径。
            if(state==S_REQUEST)current_last<=current_len-1'b1;
            if(state==S_READ && !ahead_valid && (current_lane?can0:can1))begin
                ahead_base<=opposite_base;ahead_len<=opposite_len;ahead_valid<=1;
            end
            case(state)
                S_IDLE:if(running)begin
                    if(stop || stop_pending || all_done)begin state<=S_FINISH;end
                    else if((!lane_turn && can0) || !can1 && can0)begin
                        current_lane<=0;active_lane<=0;current_base<=next0;
                        state<=S_PREPARE;
                    end else if(can1)begin
                        current_lane<=1;active_lane<=1;current_base<=next1;
                        state<=S_PREPARE;
                    end
                end
                S_PREPARE:begin
                    current_len<=prepared_len;state<=S_REQUEST;
                end
                S_REQUEST:if(stop || stop_pending)state<=S_FINISH;
                          else if(read_error)begin error<=1;error_code<=3;state<=S_FINISH;end
                          else if(read_accept && read_req)begin state<=S_READ;ahead_valid<=0;ahead_ready<=0;burst_complete<=0;end
                S_READ:begin
                    if(read_valid)begin
                        burst_complete<=read_last && words_seen==current_last;
                        if((current_lane==0 && !fifo0_ready) || (current_lane==1 && !fifo1_ready))begin
                            error<=1;error_code<=1;
                        end else begin
                            if(beat_fault)begin error<=1;error_code<=2;end
                        end
                    end
                    if(read_error)begin error<=1;error_code<=3;end
                    if(read_done)begin
                        lane_turn<=~current_lane;
                        if(completion_fault)begin error<=1;error_code<=4;end
                        else begin
                            if(current_lane==0)begin next0<=next0+current_len;remaining0<=remaining0-current_len;end
                            else begin next1<=next1+current_len;remaining1<=remaining1-current_len;end
                            burst_count<=burst_count+1'b1;
                            if(chain_request && !stop && !stop_pending)begin
                                current_lane<=~current_lane;active_lane<=~current_lane;
                                current_base<=ahead_base;current_len<=ahead_len;current_last<=ahead_last;
                                ahead_valid<=0;ahead_ready<=0;burst_complete<=0;
                            end
                        end
                        // promote已蕴含完整、无错误且无stop，许可返回仅经过最高优先选择。
                        if(promote)state<=S_READ;
                        else if(completion_fault || stop || stop_pending)state<=S_FINISH;
                        else if(chain_request)state<=S_REQUEST;
                        else state<=S_IDLE;
                    end
                end
                S_FINISH:begin running<=0;done<=1;state<=S_IDLE;end
            endcase
        end
    end
endmodule
