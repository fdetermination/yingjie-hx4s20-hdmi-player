`timescale 1ns/1ps
// 自主SDR命令后端。cmd为单行内1..256word；写预装后运行，读端须预留整burst空间。
// 命令/写数据在mem上升沿寄存；外部PHY时钟由PLL提供，独立采样时钟捕获DQ后在mem域发布。
module sdram_cmd_controller #(
    parameter integer INIT_WAIT_CYCLES=25000,REFRESH_CYCLES=1875,
    parameter integer T_RCD=3,T_RP=3,T_RAS=7,T_RFC=10,T_MRD=2,T_WR=2,CL=3,
    parameter integer INPUT_TIMEOUT_CYCLES=1000000
)(
    input wire clk,read_capture_clk,rst,
    output reg sdram_cke,sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,
    output reg [10:0] sdram_addr,
    output reg [1:0] sdram_ba,
    inout wire [31:0] sdram_dq,
    output reg [3:0] sdram_dm,
    output reg init_done,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire cmd_write,
    input wire [20:0] cmd_addr,
    input wire [8:0] cmd_len,
    input wire wr_valid,
    output wire wr_ready,
    input wire [31:0] wr_data,
    input wire [3:0] wr_mask,
    output reg rd_valid,
    output reg [31:0] rd_data,
    output reg rd_last,
    input wire rd_ready,
    output reg done,error,
    output reg [3:0] error_code,
    input wire abort,
    output wire cancel_ack,
    output wire busy
);
    localparam POWER=0,INIT_PRE=1,DELAY=2,INIT_REF1=3,INIT_REF2=4,MODE=5,
        IDLE=6,COLLECT=7,ACT=8,WRITE=9,WRITE_RUN=10,WRITE_STOP=11,
        READ=12,READ_RUN=13,CLOSE_WAIT=14,CLOSE=15,COMPLETE=16,
        REFRESH=17,REFRESH_END=18,CANCELED=19,RESUME_WRITE=20,CMD_CHECK=21;
    localparam [31:0] REFRESH_TRIGGER=REFRESH_CYCLES-300;
    localparam integer REFRESH_BITS=(REFRESH_TRIGGER==0)?1:$clog2({1'b0,REFRESH_TRIGGER}+33'd1);
    reg [4:0] state,resume_state,refresh_return;
    reg [31:0] delay_count,power_count,input_wait;
    reg [REFRESH_BITS-1:0] refresh_age;
    reg refresh_due;
    reg [15:0] active_age;
    reg [20:0] address;
    reg [8:0] length,last_index,fill_count,send_index,read_count,elapsed;
    reg writing,cancel_pending,transaction_error;
    reg command_ok;
    reg cancel_safe;
    reg [3:0] pending_error;
    (* ram_style="bram" *) reg [35:0] write_buffer[0:255];
    reg [35:0] write_word;
    wire [7:0] buffer_read_address=state==WRITE?8'd1:state==WRITE_RUN?(send_index[7:0]+8'd1):8'd0;
    reg dq_enable;
    reg [31:0] dq_out;
    wire [9:0] column_end={2'b0,cmd_addr[7:0]}+{1'b0,cmd_len};
    wire command_range_ok=cmd_len!=0 && !(cmd_len[8] && |cmd_len[7:0]) &&
        !column_end[9] && !(column_end[8] && |column_end[7:0]);
    assign sdram_dq=dq_enable?dq_out:32'bz;
    assign cmd_ready=init_done && state==IDLE && !refresh_due && !abort;
    assign wr_ready=state==COLLECT && !refresh_due && !abort;
    assign cancel_ack=cancel_safe;
    assign busy=state!=IDLE;

    // 写buffer读口预取：WRITE时word0已稳定；每周期预取下个word。
    always @(posedge clk)begin
        if(wr_valid && wr_ready)write_buffer[fill_count[7:0]]<={wr_mask,wr_data};
        if(state==ACT || state==DELAY || state==RESUME_WRITE || state==WRITE || state==WRITE_RUN)
            write_word<=write_buffer[buffer_read_address];
    end
    // 0.625ns采样域持续捕获前一PHY周期的有效字；valid/last在mem域限定发布。
    // payload无需复位，初始化/取消期间禁止发布，避免不必要的跨域SR路径。
    reg [31:0] capture_data;
    always @(posedge read_capture_clk)capture_data<=sdram_dq;
    always @(posedge clk or posedge rst)
        if(rst)rd_data<=0;else rd_data<=capture_data;

    // 合封PAD共用读/写/三态复位脚，在采样域同步释放，为mem输出保留7.375ns恢复窗口。
    wire io_rst;
    reset_sync io_reset(.clk(read_capture_clk),.rst_in(rst),.rst_out(io_rst));
    // POWER资格在mem域寄存；PAD仍按采样域复位，上电计数多等一拍。
    reg power_reset_active;
    always @(posedge clk or posedge rst)
        if(rst)power_reset_active<=1;else power_reset_active<=io_rst;
    always @(posedge clk or posedge io_rst)begin
        if(io_rst)begin sdram_cke<=1;sdram_cs_n<=0;sdram_ras_n<=1;sdram_cas_n<=1;sdram_we_n<=1;
            sdram_addr<=0;sdram_ba<=0;sdram_dm<=0;dq_enable<=0;dq_out<=0;end
        else begin
            sdram_cke<=1;sdram_cs_n<=0;sdram_ras_n<=1;sdram_cas_n<=1;sdram_we_n<=1;
            sdram_addr<=0;sdram_ba<=address[20:19];sdram_dm<=0;dq_enable<=0;dq_out<=write_word[31:0];
            case(state)
                INIT_PRE:begin sdram_ras_n<=0;sdram_we_n<=0;sdram_addr[10]<=1;end
                INIT_REF1,INIT_REF2,REFRESH:begin sdram_ras_n<=0;sdram_cas_n<=0;end
                MODE:begin sdram_ras_n<=0;sdram_cas_n<=0;sdram_we_n<=0;
                    sdram_addr<=(CL<<4)|7;sdram_ba<=0;end // full-page顺序burst
                ACT:begin sdram_ras_n<=0;sdram_addr<=address[18:8];end
                WRITE,WRITE_RUN:begin
                    dq_enable<=1;sdram_dm<=write_word[35:32];
                    if(state==WRITE)begin sdram_cas_n<=0;sdram_we_n<=0;sdram_addr<={3'b0,address[7:0]};end
                end
                WRITE_STOP: sdram_we_n<=0;
                READ:begin sdram_cas_n<=0;sdram_addr<={3'b0,address[7:0]};end
                READ_RUN:if(elapsed==last_index)sdram_we_n<=0;
                CLOSE:begin sdram_ras_n<=0;sdram_we_n<=0;end // 单bank预充
            endcase
        end
    end
    task delay_to(input integer clocks,input [4:0] next_state);
        begin delay_count<=clocks-1;resume_state<=next_state;state<=DELAY;end
    endtask
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=POWER;resume_state<=IDLE;refresh_return<=IDLE;delay_count<=0;power_count<=0;
            refresh_age<=0;refresh_due<=(REFRESH_TRIGGER==0);input_wait<=0;active_age<=0;address<=0;length<=0;last_index<=0;fill_count<=0;
            send_index<=0;read_count<=0;elapsed<=0;writing<=0;cancel_pending<=0;cancel_safe<=0;transaction_error<=0;pending_error<=0;
            command_ok<=0;
            init_done<=0;rd_valid<=0;rd_last<=0;done<=0;error<=0;error_code<=0;
        end else begin
            rd_valid<=0;rd_last<=0;done<=0;
            // 到期后保持请求；阈值后的数值不参与协议，无需32bit饱和计数和宽组合比较。
            if(init_done && !refresh_due)begin
                refresh_age<=refresh_age+1'b1;
                refresh_due<=(refresh_age==REFRESH_TRIGGER-1'b1);
            end
            if(active_age<65535)active_age<=active_age+1'b1;
            if(abort)cancel_pending<=1;
            if(rd_valid && !rd_ready)begin transaction_error<=1;pending_error<=3;end
            case(state)
                POWER:if(power_reset_active)power_count<=0;
                      else if(power_count>=INIT_WAIT_CYCLES-1)state<=INIT_PRE;else power_count<=power_count+1'b1;
                INIT_PRE:delay_to(T_RP,INIT_REF1);
                INIT_REF1:delay_to(T_RFC,INIT_REF2);
                INIT_REF2:delay_to(T_RFC,MODE);
                MODE:delay_to(T_MRD,IDLE);
                DELAY:if(delay_count==0)state<=resume_state;else delay_count<=delay_count-1'b1;
                IDLE:begin
                    if(!init_done)begin init_done<=1;refresh_age<=0;refresh_due<=(REFRESH_TRIGGER==0);end
                    if(abort || cancel_pending)state<=CANCELED;
                    else if(refresh_due)begin refresh_return<=IDLE;state<=REFRESH;end
                    else if(cmd_valid && cmd_ready)begin
                        cancel_safe<=0;
                        error<=0;error_code<=0;transaction_error<=0;pending_error<=0;
                        address<=cmd_addr;length<=cmd_len;last_index<=cmd_len-1'b1;writing<=cmd_write;fill_count<=0;input_wait<=0;
                        command_ok<=command_range_ok;state<=CMD_CHECK;
                    end
                end
                // Accepted payload is private before validation or any SDRAM command.
                CMD_CHECK:if(abort || cancel_pending)state<=CANCELED;
                          else if(!command_ok)begin error<=1;error_code<=1;done<=1;state<=IDLE;end
                          else state<=writing?COLLECT:ACT;
                COLLECT:begin
                    if(abort || cancel_pending)state<=CANCELED;
                    else if(refresh_due)begin refresh_return<=COLLECT;state<=REFRESH;end
                    else if(wr_valid && wr_ready)begin
                        input_wait<=0;
                        if(fill_count==last_index)state<=RESUME_WRITE;
                        else fill_count<=fill_count+1'b1;
                    end else if(input_wait>=INPUT_TIMEOUT_CYCLES-1)begin error<=1;error_code<=2;done<=1;state<=IDLE;end
                    else input_wait<=input_wait+1'b1;
                end
                RESUME_WRITE:if(abort || cancel_pending)state<=CANCELED;
                             else if(refresh_due)begin refresh_return<=RESUME_WRITE;state<=REFRESH;end
                             else state<=ACT;
                ACT:begin active_age<=0;delay_to(T_RCD,writing?WRITE:READ);end
                WRITE:begin send_index<=1;if(length==1)state<=WRITE_STOP;else state<=WRITE_RUN;end
                WRITE_RUN:if(send_index==last_index)state<=WRITE_STOP;else send_index<=send_index+1'b1;
                WRITE_STOP:begin delay_count<=T_WR;state<=CLOSE_WAIT;end
                READ:begin elapsed<=0;read_count<=0;state<=READ_RUN;end
                READ_RUN:begin
                    elapsed<=elapsed+1'b1;
                    if(elapsed>=CL+1 && read_count<length)begin
                        rd_valid<=!(abort || cancel_pending);
                        rd_last<=read_count==last_index;read_count<=read_count+1'b1;
                        // 末字已经过采样和mem发布，不再重复等待CAS；tRAS和PRE后的tRP继续单独检查。
                        if(read_count==last_index)begin delay_count<=0;state<=CLOSE_WAIT;end
                    end
                end
                CLOSE_WAIT:if(delay_count!=0)delay_count<=delay_count-1'b1;
                           else if(active_age>=T_RAS)state<=CLOSE;
                CLOSE:delay_to(T_RP,COMPLETE);
                COMPLETE:begin
                    if(abort || cancel_pending)state<=CANCELED;
                    else begin done<=1;error<=transaction_error;error_code<=pending_error;state<=IDLE;end
                end
                REFRESH:begin refresh_age<=0;refresh_due<=(REFRESH_TRIGGER==0);delay_to(T_RFC,REFRESH_END);end
                REFRESH_END:if(abort || cancel_pending)state<=CANCELED;else state<=refresh_return;
                CANCELED:begin
                    cancel_safe<=1;
                    if(refresh_due)begin refresh_return<=CANCELED;state<=REFRESH;end
                    else if(!abort)begin cancel_safe<=0;cancel_pending<=0;error<=0;error_code<=0;state<=IDLE;end
                end
            endcase
        end
    end
endmodule
