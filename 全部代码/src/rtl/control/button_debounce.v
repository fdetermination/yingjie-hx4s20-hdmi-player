`timescale 1ns/1ps
// 低有效异步按键：两级同步后连续稳定CYCLES拍才更新按下电平。
module button_debounce #(parameter integer CYCLES=2500000)(
    input wire clk,rst,key_n,
    output reg pressed
);
    localparam COUNT_BITS=CYCLES<2?1:$clog2(CYCLES);
    (* async_reg="true" *) reg key_meta,key_sync;
    reg [COUNT_BITS-1:0] count;
    always @(posedge clk or posedge rst)begin
        if(rst)begin key_meta<=1;key_sync<=1;count<=0;pressed<=0;end
        else begin
            key_meta<=key_n;key_sync<=key_meta;
            if(!key_sync==pressed)count<=0;
            else if(count==CYCLES-1)begin pressed<=!key_sync;count<=0;end
            else count<=count+1'b1;
        end
    end
endmodule
