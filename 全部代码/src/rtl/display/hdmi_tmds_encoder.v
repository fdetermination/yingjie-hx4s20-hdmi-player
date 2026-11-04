`timescale 1ns/1ps
// 自主HDMI TMDS单通道编码器。ctrl0=HSYNC，ctrl1=VSYNC；数据在de期间做运行差分平衡。
module hdmi_tmds_encoder(
    input wire clk,rst,
    input wire de,ctrl0,ctrl1,
    input wire [7:0] data,
    output reg [9:0] code,
    output reg signed [4:0] disparity
);
    reg [8:0] q_m;
    integer ones_data,ones_qm,i,delta;
    reg xnor_mode;
    always @(posedge clk or posedge rst)begin
        if(rst)begin code<=10'b1101010100;disparity<=0;end
        else if(!de)begin
            case({ctrl1,ctrl0})
                2'b00:code<=10'b1101010100;
                2'b01:code<=10'b0010101011;
                2'b10:code<=10'b0101010100;
                default:code<=10'b1010101011;
            endcase
            disparity<=0;
        end else begin
            ones_data=0;
            for(i=0;i<8;i=i+1)ones_data=ones_data+data[i];
            xnor_mode=(ones_data>4)||(ones_data==4 && data[0]==0);
            q_m[0]=data[0];
            for(i=1;i<8;i=i+1)q_m[i]=q_m[i-1]^data[i]^xnor_mode;
            q_m[8]=~xnor_mode;
            ones_qm=0;
            for(i=0;i<8;i=i+1)ones_qm=ones_qm+q_m[i];
            if(disparity==0 || ones_qm==4)begin
                code<={~q_m[8],q_m[8],q_m[8]?q_m[7:0]:~q_m[7:0]};
                delta=q_m[8]?(2*ones_qm-8):(8-2*ones_qm);
            end else if((disparity>0 && ones_qm>4)||(disparity<0 && ones_qm<4))begin
                code<={1'b1,q_m[8],~q_m[7:0]};
                delta=(q_m[8]?2:0)+(8-2*ones_qm);
            end else begin
                code<={1'b0,q_m[8],q_m[7:0]};
                delta=(q_m[8]?0:-2)+(2*ones_qm-8);
            end
            disparity<=disparity+delta;
        end
    end
endmodule
