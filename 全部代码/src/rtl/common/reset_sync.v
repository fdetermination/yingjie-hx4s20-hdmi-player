`timescale 1ns/1ps
// 异步置位、各域独立两拍释放；rst_in由外部复位和PLL未锁定共同驱动。
module reset_sync #(parameter integer RELEASE_NEGEDGE=0)(input wire clk,rst_in,output wire rst_out);
    (* async_reg="true" *) reg [1:0] reset_pipe;
    generate if(RELEASE_NEGEDGE)begin
        always @(negedge clk or posedge rst_in)
            if(rst_in)reset_pipe<=2'b11;else reset_pipe<={reset_pipe[0],1'b0};
    end else begin
        always @(posedge clk or posedge rst_in)
            if(rst_in)reset_pipe<=2'b11;else reset_pipe<={reset_pipe[0],1'b0};
    end endgenerate
    assign rst_out=reset_pipe[1];
endmodule
