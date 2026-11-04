`timescale 1ns/1ps
// 单在途文件命令寄存桥：切断应用状态到FAT/SPI命令扇出，过滤命令前的保持型done/error。
// 单字节非直通缓存切断ready返回路径；物理终态等待缓存消费后才释放应用owner。
module file_command_bridge(
    input wire clk,rst,app_abort,app_cmd_valid,
    output wire app_cmd_ready,
    input wire [2:0] app_cmd_op,
    input wire app_cmd_channel,
    input wire [27:0] app_cmd_cluster,
    input wire [31:0] app_cmd_size,
    output reg app_done,app_error,app_open_complete,
    output wire app_cancel_ack,app_data_valid,app_file_last,
    output wire [7:0] app_data_byte,
    input wire app_data_ready,
    output wire service_cmd_valid,
    output reg [2:0] service_cmd_op,
    output reg service_cmd_channel,
    output reg [27:0] service_cmd_cluster,
    output reg [31:0] service_cmd_size,
    input wire service_cmd_ready,service_done,service_error,service_cancel_ack,service_open_complete,
    output wire service_abort,
    input wire service_data_valid,service_file_last,
    input wire [7:0] service_data_byte,
    output wire service_data_ready
);
    localparam IDLE=0,COMMAND=1,RESPONSE=2,CANCEL=3,CANCEL_DONE=4;
    reg [2:0] state;
    reg [8:0] byte_buffer;
    reg byte_full,terminal_pending,terminal_error,terminal_open_complete;
    assign app_cmd_ready=state==IDLE && !app_abort && !rst;
    assign service_cmd_valid=state==COMMAND && !app_abort;
    assign service_abort=state==CANCEL;
    assign app_cancel_ack=state==CANCEL_DONE;
    assign app_data_valid=state==RESPONSE && !app_abort && byte_full;
    assign app_file_last=byte_buffer[8];
    assign app_data_byte=byte_buffer[7:0];
    assign service_data_ready=state==RESPONSE && !app_abort && !byte_full && !terminal_pending;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;app_done<=0;app_error<=0;app_open_complete<=0;service_cmd_op<=0;service_cmd_channel<=0;service_cmd_cluster<=0;service_cmd_size<=0;
            byte_buffer<=0;byte_full<=0;terminal_pending<=0;terminal_error<=0;terminal_open_complete<=0;
        end else if(app_abort && state!=CANCEL && state!=CANCEL_DONE)begin
            // 未接受的命令、空闲和同拍终态均没有需要取消的后端owner。
            state<=(state==RESPONSE && !terminal_pending && !service_done && !service_error)?CANCEL:CANCEL_DONE;
            app_done<=0;app_error<=0;app_open_complete<=0;
            byte_full<=0;terminal_pending<=0;terminal_error<=0;terminal_open_complete<=0;
        end else case(state)
            IDLE:if(app_cmd_valid && app_cmd_ready)begin
                service_cmd_op<=app_cmd_op;service_cmd_channel<=app_cmd_channel;
                service_cmd_cluster<=app_cmd_cluster;service_cmd_size<=app_cmd_size;
                app_done<=0;app_error<=0;app_open_complete<=0;state<=COMMAND;
                byte_full<=0;terminal_pending<=0;terminal_error<=0;terminal_open_complete<=0;
            end
            COMMAND:if(service_cmd_valid && service_cmd_ready)state<=RESPONSE;
            RESPONSE:begin
                if(service_data_valid && service_data_ready)begin
                    byte_buffer<={service_file_last,service_data_byte};byte_full<=1;
                end else if(byte_full && app_data_ready)byte_full<=0;
                if(!terminal_pending && (service_error || service_done))begin
                    terminal_pending<=1;terminal_error<=service_error;
                    terminal_open_complete<=service_done && !service_error && service_open_complete &&
                        (service_cmd_op==2 || service_cmd_op==4 || service_cmd_op==5);
                end
                // 只消费已保存的终态，避免同拍接受末字节时提前done/换owner。
                if(terminal_pending && !byte_full)begin
                    app_error<=terminal_error;app_done<=!terminal_error;app_open_complete<=terminal_open_complete;
                    terminal_pending<=0;state<=IDLE;
                end
            end
            CANCEL:if(service_cancel_ack)state<=CANCEL_DONE;
            CANCEL_DONE:if(!app_abort)state<=IDLE;
        endcase
    end
endmodule
