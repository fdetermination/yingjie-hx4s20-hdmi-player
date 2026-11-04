`timescale 1ns/1ps
// 帧事务到SDRAM行内burst；应用写buffer与显示读锁分离，flush/cancel以backend done为准。
module frame_store_adapter #(
    parameter integer FRAME_WORDS=921600,TOKEN_BITS=8
)(
    input wire clk,rst,
    input wire mem_begin_req,
    output wire mem_begin_accept,
    input wire mem_bank,
    input wire [TOKEN_BITS-1:0] mem_token,
    input wire [1:0] display_locks,
    input wire mem_write_valid,
    output wire mem_write_ready,
    input wire [20:0] mem_write_address,
    input wire [31:0] mem_write_data,
    input wire mem_flush_req,
    output wire mem_flush_ack,
    output reg mem_error,
    output reg [TOKEN_BITS-1:0] mem_response_token,
    input wire mem_cancel,
    output wire mem_cancel_ack,
    input wire read_req,
    output wire read_accept,
    input wire [20:0] read_address,
    input wire [8:0] read_length,
    output wire read_valid,
    input wire read_ready,
    output wire [31:0] read_data,
    output wire read_last,
    output reg read_done,read_error,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire cmd_write,
    output wire [20:0] cmd_addr,
    output wire [8:0] cmd_len,
    output wire wr_valid,
    input wire wr_ready,
    output wire [31:0] wr_data,
    output wire [3:0] wr_mask,
    input wire backend_rd_valid,backend_rd_last,
    input wire [31:0] backend_rd_data,
    output wire backend_rd_ready,
    input wire backend_done,backend_error,
    output wire backend_abort,
    input wire backend_cancel_ack,
    output wire writer_active
);
    localparam SERVICE=0,WRITE_COMMAND=1,WRITE_FETCH=2,WRITE_SEND=3,WRITE_WAIT=4,
        READ_COMMAND=5,READ_WAIT=6,FLUSH_ACK=7,CANCEL_WAIT=8;
    reg [3:0] state;
    reg transaction_active,bank;
    reg [20:0] base,read_base,next_address;
    reg [8:0] count,send_index,read_len;
    reg [2:0] read_streak;
    reg fault_latched,cancel_pending,cancel_confirmed;
    reg write_prepared,address_ok,contiguous_ok;
    (* ram_style="bram" *) reg [31:0] buffer[0:255];
    reg [31:0] out_word;
    wire write_bank_safe=!display_locks[bank];
    wire write_address_valid=address_ok;
    wire write_fault=transaction_active && (!write_bank_safe || (mem_write_valid && write_prepared && !write_address_valid));
    wire next_contiguous=count==0 || contiguous_ok;
    wire need_send=count!=0 && (count==256 || next_address[7:0]==0 || mem_flush_req ||
                                (mem_write_valid && write_prepared && !next_contiguous));
    wire read_frame_range;
    generate if(FRAME_WORDS>0 && FRAME_WORDS<=1048576 && FRAME_WORDS%256==0)begin: aligned_read_range
        // 帧边界整页对齐，页内burst只需校验起点；保留第二帧严格上界。
        assign read_frame_range=read_address<FRAME_WORDS?display_locks[0]:
            (read_address<2*FRAME_WORDS && display_locks[1]);
    end else begin: generic_read_range
        assign read_frame_range=read_address<FRAME_WORDS ? (read_address+read_length<=FRAME_WORDS && display_locks[0]) :
            (read_address>=FRAME_WORDS && read_address+read_length<=2*FRAME_WORDS && display_locks[1]);
    end endgenerate
    wire read_address_valid=read_length!=0 && read_length<=256 &&
        {1'b0,read_address[7:0]}+{1'b0,read_length}<=256 && read_frame_range;
    wire writer_waiting=(count!=0 && (count==256 || next_address[7:0]==0)) ||
        (mem_flush_req && (count!=0 || (transaction_active && !fault_latched))) ||
        (mem_write_valid && ((count!=0 && write_prepared && !contiguous_ok) ||
                            (transaction_active && !fault_latched)));
    wire grant_read=read_req && read_address_valid && (!writer_waiting || read_streak<4);
    // 写ready资格已排除need_send/flush，此时writer_waiting等于mem_write_valid。
    wire write_read_priority=read_req && read_address_valid && (!mem_write_valid || read_streak<4);
    wire cancel_to_backend=(mem_cancel || cancel_pending) && !cancel_confirmed &&
        state!=READ_COMMAND && state!=READ_WAIT && state!=CANCEL_WAIT;
    wire service_cycle=state==SERVICE && !cancel_to_backend;
    assign writer_active=transaction_active;
    assign mem_begin_accept=state==SERVICE && !transaction_active && !mem_cancel && !cancel_confirmed && !display_locks[mem_bank];
    assign mem_write_ready=state==SERVICE && transaction_active && !mem_cancel && !mem_flush_req && !fault_latched &&
        write_prepared && write_bank_safe && write_address_valid && !need_send && !write_read_priority;
    assign read_accept=state==SERVICE && (!mem_cancel || cancel_confirmed) && !write_fault && grant_read;
    assign mem_flush_ack=state==FLUSH_ACK && !mem_cancel;
    assign mem_cancel_ack=cancel_confirmed;
    assign backend_abort=state==CANCEL_WAIT;
    // 写取消仅撤销写事务；已经承诺给显示端的读必须完整返回。
    assign cmd_valid=(state==WRITE_COMMAND && !mem_cancel) || state==READ_COMMAND;
    assign cmd_write=state==WRITE_COMMAND;
    assign cmd_addr=state==WRITE_COMMAND?base:read_base;
    assign cmd_len=state==WRITE_COMMAND?count:read_len;
    assign wr_valid=state==WRITE_SEND && !mem_cancel;
    assign wr_data=out_word;
    assign wr_mask=0;
    assign read_valid=state==READ_WAIT && backend_rd_valid;
    assign read_data=backend_rd_data;
    assign read_last=backend_rd_last;
    assign backend_rd_ready=state==READ_WAIT && read_ready;
    // Input payload stays stable until ready; prepare the address before arbitration.
    always @(posedge clk or posedge rst)begin
        if(rst)begin write_prepared<=0;address_ok<=0;contiguous_ok<=0;end
        else if(!transaction_active || mem_cancel || !mem_write_valid || mem_write_ready)write_prepared<=0;
        else if(!write_prepared)begin
            write_prepared<=1;
            address_ok<=bank?(mem_write_address>=FRAME_WORDS && mem_write_address<2*FRAME_WORDS):mem_write_address<FRAME_WORDS;
            contiguous_ok<=mem_write_address==next_address && next_address[7:0]!=0;
        end
    end
    always @(posedge clk)begin
        if(mem_write_valid && mem_write_ready)buffer[count[7:0]]<=mem_write_data;
        if(state==WRITE_FETCH)out_word<=buffer[send_index[7:0]];
    end
    always @(posedge clk or posedge rst)begin
        if(rst)read_streak<=0;
        else if(service_cycle)begin
            if(read_accept)begin
                if(read_streak<4)read_streak<=read_streak+1'b1;
            end else if((!write_fault && need_send && !fault_latched) ||
                        (mem_write_valid && mem_write_ready))read_streak<=0;
        end
    end
    // 原SERVICE/WRITE_WAIT错误赋值会覆盖前置清零，保留置位优先级。
    always @(posedge clk or posedge rst)begin
        if(rst)fault_latched<=0;
        else if((service_cycle && write_fault) ||
                (state==WRITE_WAIT && !cancel_to_backend && backend_done && backend_error))fault_latched<=1;
        else if((cancel_confirmed && !mem_cancel) ||
                (service_cycle && mem_begin_req && mem_begin_accept))fault_latched<=0;
    end
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=SERVICE;transaction_active<=0;bank<=0;base<=0;read_base<=0;next_address<=0;count<=0;send_index<=0;read_len<=0;
            mem_error<=0;mem_response_token<=0;read_done<=0;read_error<=0;
            cancel_pending<=0;cancel_confirmed<=0;
        end else begin
            read_done<=0;read_error<=0;
            if(mem_cancel && !cancel_confirmed)cancel_pending<=1;
            if(cancel_confirmed && !mem_cancel)begin cancel_confirmed<=0;mem_error<=0;end
            if(cancel_to_backend)begin state<=CANCEL_WAIT;end
            else case(state)
                SERVICE:begin
                    if(mem_begin_req && mem_begin_accept)begin
                        transaction_active<=1;bank<=mem_bank;mem_response_token<=mem_token;count<=0;
                        mem_error<=0;
                    end
                    if(write_fault)begin
                        mem_error<=1;
                    end else if(read_accept)begin
                        read_base<=read_address;read_len<=read_length;state<=READ_COMMAND;
                    end else if(need_send && !fault_latched)begin state<=WRITE_COMMAND;send_index<=0;end
                    else if(mem_flush_req && transaction_active && count==0 && !fault_latched)begin
                        state<=FLUSH_ACK;transaction_active<=0;
                    end else if(mem_write_valid && mem_write_ready)begin
                        if(count==0)base<=mem_write_address;
                        count<=count+1'b1;next_address<=mem_write_address+1'b1;
                    end
                    if(read_req && !read_address_valid)read_error<=1;
                end
                WRITE_COMMAND:if(cmd_ready)state<=WRITE_FETCH;
                WRITE_FETCH:state<=WRITE_SEND;
                WRITE_SEND:if(wr_ready)begin
                    if(send_index==count-1'b1)state<=WRITE_WAIT;
                    else begin send_index<=send_index+1'b1;state<=WRITE_FETCH;end
                end
                WRITE_WAIT:if(backend_done)begin
                    if(backend_error)begin mem_error<=1;end
                    count<=0;state<=SERVICE;
                end
                READ_COMMAND:if(cmd_ready)state<=READ_WAIT;
                READ_WAIT:if(backend_done)begin
                    read_done<=1;read_error<=backend_error;
                    state<=((mem_cancel || cancel_pending) && !cancel_confirmed)?CANCEL_WAIT:SERVICE;
                end
                FLUSH_ACK:if(!mem_flush_req)state<=SERVICE;
                CANCEL_WAIT:if(backend_cancel_ack)begin
                    count<=0;transaction_active<=0;cancel_pending<=0;cancel_confirmed<=1;state<=SERVICE;
                end
            endcase
        end
    end
endmodule
