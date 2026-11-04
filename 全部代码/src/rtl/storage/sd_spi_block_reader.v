`timescale 1ns/1ps
// 独立SD SPI读块：初始化/CRC7命令/CRC16数据校验/整块后发布/取消释放。
// SDHC/SDXC使用块地址；SDSC使用字节地址。块大小固定512，未实现写卡。
module sd_spi_block_reader #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer POWERUP_CYCLES=CLK_FREQ_HZ/1000,
    parameter integer INIT_DIVIDER=125,
    parameter integer FAST_DIVIDER=2,
    parameter integer INIT_TIMEOUT_CYCLES=CLK_FREQ_HZ,
    parameter integer TOKEN_TIMEOUT_CYCLES=CLK_FREQ_HZ/10
)(
    input wire clk,rst,abort,
    input wire block_req,
    output wire block_accept,
    input wire [31:0] block_lba,
    output wire block_valid,
    input wire block_ready,
    output reg [7:0] block_data,
    output wire block_last,
    output reg block_error,block_done,block_cancel_ack,
    output reg sd_cs_n,
    output wire sd_sclk,sd_mosi,
    input wire sd_miso,
    output reg init_done,high_capacity,
    output reg [3:0] error_code,
    output wire [7:0] response_byte
);
    localparam POWER=0,CLOCKS=1,CLOCK_DONE=2,GAP=3,SELECT=4,COMMAND=5,COMMAND_DONE=6,
        RESPONSE=7,RESPONSE_DONE=8,EXTENDED=9,EXTENDED_DONE=10,IDLE=11,
        TOKEN=12,TOKEN_DONE=13,READ=14,READ_DONE=15,CRC_HIGH=16,CRC_HIGH_DONE=17,
        CRC_LOW=18,CRC_LOW_DONE=19,RELEASE=20,RELEASE_DONE=21,
        OUTPUT_FETCH=22,OUTPUT_HOLD=23,FAILED=24,CANCEL=25,CANCEL_RELEASE=26,
        CANCEL_DONE=27,XFER_WAIT=28,XFER_GUARD=29;
    reg [4:0] state,return_state;
    reg [5:0] command_id;
    reg [31:0] argument,extended_response;
    reg [7:0] command_crc;
    reg [2:0] command_index;
    reg [3:0] response_count,clock_bytes;
    reg [1:0] extended_index;
    reg v2_card;
    reg r1_retains_cs,r1_idle_response;
    reg [31:0] timer,init_timer;
    reg init_timeout_reached;
    reg [8:0] data_index,output_index;
    reg [15:0] crc,received_crc;
    reg [7:0] memory[0:511];
    reg spi_start,spi_abort;
    reg cs_requested;
    reg [7:0] spi_tx;
    wire [7:0] spi_rx;
    assign response_byte=spi_rx;
    wire r1_matches=spi_rx==(r1_idle_response?8'd1:8'd0);
    wire spi_busy,spi_done;
    wire [15:0] clock_divider=init_done?FAST_DIVIDER:INIT_DIVIDER;
    // 初始化完成后watchdog不再使用该位，改作已初始化读事务的取消锁存。
    wire cancel_pending=init_done && init_timeout_reached;
    wire cancel_state=state==CANCEL || state==CANCEL_RELEASE || state==CANCEL_DONE ||
        ((state==XFER_WAIT || state==XFER_GUARD) && return_state==CANCEL_DONE);
    wire cancelling=cancel_pending || cancel_state;
    sd_spi_byte_engine #(.DELAY_MISO_SAMPLE(1),.COMPLETE_ABORT_HIGH(1)) spi(.clk(clk),.rst(rst),.abort(spi_abort),.start(spi_start),
        .tx_data(spi_tx),.divider(clock_divider),.miso(sd_miso),.rx_data(spi_rx),
        .busy(spi_busy),.done(spi_done),.sclk(sd_sclk),.mosi(sd_mosi));
    // A delayed CS release follows the last possible clock edge on cancellation.
    always @(posedge clk or posedge rst)
        if(rst)sd_cs_n<=1;else sd_cs_n<=cs_requested;
    assign block_accept=state==IDLE && init_done && !abort && !cancel_pending;
    assign block_valid=state==OUTPUT_HOLD && !abort && !cancel_pending;
    assign block_last=block_valid && output_index==511;
    function [7:0] crc7_command;
        input [5:0] id;input [31:0] arg;
        reg [39:0] packet;reg [6:0] c;integer k;
        begin
            packet={2'b01,id,arg};c=0;
            for(k=39;k>=0;k=k-1) begin
                if(c[6]^packet[k]) c=(c<<1)^7'h09;else c=c<<1;
            end
            crc7_command={c,1'b1};
        end
    endfunction
    function [15:0] crc16_byte;
        input [15:0] old_crc;input [7:0] value;
        reg [15:0] c;integer k;
        begin c=old_crc^{value,8'd0};
            for(k=0;k<8;k=k+1)c=c[15]?((c<<1)^16'h1021):(c<<1);
            crc16_byte=c;
        end
    endfunction
    task transfer;
        input [7:0] value;input [4:0] destination;
        begin spi_tx<=value;spi_start<=1;return_state<=destination;state<=XFER_GUARD;end
    endtask
    task issue;
        input [5:0] id;input [31:0] arg;
        begin command_id<=id;argument<=arg;command_crc<=crc7_command(id,arg);
            r1_retains_cs<=id==8 || id==58 || id==17;r1_idle_response<=id==8;
            command_index<=0;response_count<=0;cs_requested<=1;state<=GAP;end
    endtask
    task fail;
        input [3:0] code;
        begin
            error_code<=code;
            if(cancel_pending)begin block_error<=0;cs_requested<=1;state<=CANCEL;end
            else begin block_error<=1;cs_requested<=1;spi_abort<=1;state<=FAILED;end
        end
    endtask
    always @(posedge clk) begin
        if(state==READ_DONE) memory[data_index]<=spi_rx;
        if(state==OUTPUT_FETCH) block_data<=memory[output_index];
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=POWER;return_state<=POWER;timer<=0;init_timer<=0;init_timeout_reached<=(INIT_TIMEOUT_CYCLES==1);
            cs_requested<=1;init_done<=0;high_capacity<=0;v2_card<=0;r1_retains_cs<=0;r1_idle_response<=0;error_code<=0;
            block_error<=0;block_done<=0;block_cancel_ack<=0;
            command_id<=0;argument<=0;command_crc<=0;command_index<=0;
            response_count<=0;clock_bytes<=0;extended_index<=0;extended_response<=0;
            data_index<=0;output_index<=0;crc<=0;received_crc<=0;spi_start<=0;spi_abort<=0;spi_tx<=8'hff;
        end else begin
            spi_start<=0;spi_abort<=0;block_done<=0;
            if(!init_done && state!=FAILED && !cancel_state)begin
                init_timer<=init_timer+1'b1;
                // 预测递增后的到期状态，保持原到期拍，避免宽比较器串到CS/状态控制。
                init_timeout_reached<=(INIT_TIMEOUT_CYCLES==1) || init_timer>=INIT_TIMEOUT_CYCLES-2;
            end
            if(abort && !cancelling) begin
                // SPI相对CS必须保持完整字节；活动事务只锁存取消，不截断当前byte。
                block_error<=0;block_cancel_ack<=0;
                if(!init_done)begin
                    cs_requested<=1;spi_abort<=1;state<=CANCEL;
                end else begin
                    init_timeout_reached<=1;
                    if(state==IDLE || state==OUTPUT_FETCH || state==OUTPUT_HOLD || state==FAILED || state==POWER)begin
                        cs_requested<=1;state<=CANCEL;
                    end
                    else if(state==XFER_WAIT && spi_done)state<=return_state;
                end
            end else if(!init_done && !cancel_state && state!=FAILED && init_timeout_reached) fail(1);
            else case(state)
                POWER: if(timer>=POWERUP_CYCLES-1) begin state<=CLOCKS;clock_bytes<=0;end else timer<=timer+1'b1;
                CLOCKS: transfer(8'hff,CLOCK_DONE);
                CLOCK_DONE: if(clock_bytes==9) issue(0,0);else begin clock_bytes<=clock_bytes+1'b1;state<=CLOCKS;end
                GAP: transfer(8'hff,SELECT);
                SELECT: begin cs_requested<=0;state<=COMMAND;end
                COMMAND: case(command_index)
                    0:transfer({2'b01,command_id},COMMAND_DONE);
                    1:transfer(argument[31:24],COMMAND_DONE);2:transfer(argument[23:16],COMMAND_DONE);
                    3:transfer(argument[15:8],COMMAND_DONE);4:transfer(argument[7:0],COMMAND_DONE);
                    5:transfer(command_crc,COMMAND_DONE);
                endcase
                COMMAND_DONE: if(command_index==5) state<=RESPONSE;
                              else begin command_index<=command_index+1'b1;state<=COMMAND;end
                RESPONSE: transfer(8'hff,RESPONSE_DONE);
                RESPONSE_DONE: if(spi_rx[7]) begin
                    if(response_count==7)fail(2);
                    else begin response_count<=response_count+1'b1;state<=RESPONSE;end
                end else begin
                case(command_id)
                    0:if(spi_rx==1)issue(8,32'h1aa);else fail(3);
                    8:if(spi_rx==1) begin extended_index<=0;extended_response<=0;v2_card<=1;state<=EXTENDED;end
                      else if(spi_rx==5) begin v2_card<=0;issue(55,0);end else fail(4);
                    55:if(spi_rx==1 || spi_rx==0)issue(41,v2_card?32'h40000000:0);else fail(3);
                    41:if(spi_rx==1)issue(55,0);else if(spi_rx==0)issue(58,0);else fail(3);
                    58:if(spi_rx==0)begin extended_index<=0;extended_response<=0;state<=EXTENDED;end else fail(5);
                    16:if(spi_rx==0)issue(59,1);else fail(3);
                    59:if(spi_rx==0)begin init_done<=1;init_timeout_reached<=0;cs_requested<=1;state<=RELEASE;end else fail(3);
                    17:if(spi_rx==0)begin timer<=0;state<=TOKEN;end else fail(6);
                    default:fail(3);
                endcase
                // 仅CMD8/58/17的预期R1保留片选；分类在issue时已稳定。
                cs_requested<=!(r1_retains_cs && r1_matches);
                end
                EXTENDED: transfer(8'hff,EXTENDED_DONE);
                EXTENDED_DONE: begin
                    extended_response<={extended_response[23:0],spi_rx};
                    if(extended_index==3)begin
                        if(command_id==8)begin
                            if({extended_response[23:0],spi_rx}!=32'h000001aa)fail(4);else issue(55,0);
                        end else begin
                            // OCR power-up complete、3.2~3.4V窗口、CCS需全部合法。
                            if(!extended_response[23] || !(extended_response[12] || extended_response[13]) ||
                               (extended_response[22] && !v2_card)) fail(5);
                            else begin high_capacity<=extended_response[22];
                                if(extended_response[22])issue(59,1);else issue(16,512);
                            end
                        end
                    end else begin extended_index<=extended_index+1'b1;state<=EXTENDED;end
                end
                RELEASE: transfer(8'hff,RELEASE_DONE);
                RELEASE_DONE: if(cancel_pending)state<=CANCEL;else state<=IDLE;
                IDLE: if(block_req)begin
                    block_error<=0;error_code<=0;
                    if(!high_capacity && block_lba[31:23]!=0)fail(10);
                    else issue(17,high_capacity?block_lba:(block_lba<<9));
                end
                TOKEN: transfer(8'hff,TOKEN_DONE);
                TOKEN_DONE: begin
                    if(spi_rx==8'hfe)begin data_index<=0;crc<=0;state<=READ;end
                    else if(spi_rx!=8'hff)fail(7);
                    else if(timer>=TOKEN_TIMEOUT_CYCLES)fail(8);else state<=TOKEN;
                end
                READ: transfer(8'hff,READ_DONE);
                READ_DONE: begin
                    crc<=crc16_byte(crc,spi_rx);
                    if(data_index==511)state<=CRC_HIGH;
                    else begin data_index<=data_index+1'b1;state<=READ;end
                end
                CRC_HIGH: transfer(8'hff,CRC_HIGH_DONE);
                CRC_HIGH_DONE: begin received_crc[15:8]<=spi_rx;state<=CRC_LOW;end
                CRC_LOW: transfer(8'hff,CRC_LOW_DONE);
                CRC_LOW_DONE: if({received_crc[15:8],spi_rx}!=crc)fail(9);
                              else begin
                                  cs_requested<=1;
                                  if(cancel_pending)state<=CANCEL;
                                  else begin output_index<=0;state<=OUTPUT_FETCH;end
                              end
                OUTPUT_FETCH: state<=OUTPUT_HOLD;
                OUTPUT_HOLD: if(block_ready)begin
                    if(output_index==511)begin block_done<=1;state<=RELEASE;end
                    else begin output_index<=output_index+1'b1;state<=OUTPUT_FETCH;end
                end
                FAILED: begin end // 错误保持到上层取消，不能把坏扇区伪装成成功。
                CANCEL: if(!spi_busy) state<=CANCEL_RELEASE;
                CANCEL_RELEASE: transfer(8'hff,CANCEL_DONE);
                CANCEL_DONE: begin
                    block_cancel_ack<=1;
                    if(!abort && block_cancel_ack)begin
                        block_cancel_ack<=0;error_code<=0;
                        if(init_done && error_code!=2 && error_code!=6 && error_code!=7 && error_code!=8)begin
                            init_timeout_reached<=0;state<=IDLE;
                        end else begin
                            init_done<=0;state<=POWER;timer<=0;init_timer<=0;
                            init_timeout_reached<=(INIT_TIMEOUT_CYCLES==1);
                        end
                    end
                end
                XFER_GUARD: state<=XFER_WAIT;
                XFER_WAIT: if(spi_done)state<=return_state;
            endcase
            // 数据token只允许有限等待；byte传输时也累计，避免空字节重置超时。
            if(state==TOKEN || state==TOKEN_DONE ||
               ((state==XFER_WAIT || state==XFER_GUARD) && return_state==TOKEN_DONE))timer<=timer+1'b1;
        end
    end
endmodule
