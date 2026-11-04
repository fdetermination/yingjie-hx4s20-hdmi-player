`timescale 1ns/1ps
// SPI mode 0；板级模式延迟一拍采样，并在取消时完成当前高半周期。
module sd_spi_byte_engine #(
    parameter integer DELAY_MISO_SAMPLE=0,COMPLETE_ABORT_HIGH=0
)(
    input wire clk,rst,abort,start,
    input wire [7:0] tx_data,
    input wire [15:0] divider,
    input wire miso,
    output reg [7:0] rx_data,
    output reg busy,done,sclk,mosi
);
    reg [7:0] tx,rx;
    reg [2:0] bit_index;
    reg [15:0] counter,half_period;
    reg abort_pending;
    always @(posedge clk or posedge rst) begin
        if(rst) begin rx_data<=0;busy<=0;done<=0;sclk<=0;mosi<=1;
            tx<=0;rx<=0;bit_index<=0;counter<=0;half_period<=1;abort_pending<=0;end
        else if(abort || abort_pending) begin
            done<=0;
            if(COMPLETE_ABORT_HIGH && busy && sclk && counter!=half_period-1'b1)begin
                counter<=counter+1'b1;abort_pending<=1;
            end else begin busy<=0;sclk<=0;mosi<=1;counter<=0;abort_pending<=0;end
        end
        else begin
            done<=0;
            if(start && !busy) begin
                tx<=tx_data;rx<=0;bit_index<=7;counter<=0;busy<=1;sclk<=0;
                mosi<=tx_data[7];half_period<=(divider==0)?1:divider;
            end else if(busy) begin
                // With divider>=2 this occurs before the following falling edge.
                if(DELAY_MISO_SAMPLE && half_period>1 && sclk && counter==0)rx<={rx[6:0],miso};
                if(counter==half_period-1'b1) begin
                    counter<=0;
                    if(!sclk) begin
                        sclk<=1;
                        if(!DELAY_MISO_SAMPLE || half_period<=1)rx<={rx[6:0],miso};
                    end
                    else begin
                        sclk<=0;
                        if(bit_index==0) begin busy<=0;done<=1;rx_data<=rx;mosi<=1;end
                        else begin bit_index<=bit_index-1'b1;mosi<=tx[bit_index-1'b1];end
                    end
                end else counter<=counter+1'b1;
            end
        end
    end
endmodule
