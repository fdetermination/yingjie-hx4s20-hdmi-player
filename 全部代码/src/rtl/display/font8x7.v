`timescale 1ns/1ps
// 项目自绘8x7字模；大小写统一显示大写，支持数字、A-Z和常用标点。
module font8x7(input wire [7:0] character,input wire [2:0] row,output wire [7:0] bitmap);
    wire [7:0] ch=(character>=8'h61 && character<=8'h7a)?character-8'd32:character;
    reg [55:0] glyph;
    always @(*)case(ch)
        "0":glyph=56'h3c666e7666663c;"1":glyph=56'h1838181818187e;
        "2":glyph=56'h3c66060c30607e;"3":glyph=56'h3c66061c06663c;
        "4":glyph=56'h0c1c3c6c7e0c0c;"5":glyph=56'h7e607c0606663c;
        "6":glyph=56'h1c30607c66663c;"7":glyph=56'h7e66060c181818;
        "8":glyph=56'h3c66663c66663c;"9":glyph=56'h3c66663e060c38;
        "A":glyph=56'h3c66667e666666;"B":glyph=56'h7c66667c66667c;
        "C":glyph=56'h3c66606060663c;"D":glyph=56'h786c6666666c78;
        "E":glyph=56'h7e60607c60607e;"F":glyph=56'h7e60607c606060;
        "G":glyph=56'h3c66606e66663c;"H":glyph=56'h6666667e666666;
        "I":glyph=56'h7e18181818187e;"J":glyph=56'h1e0c0c0c6c6c38;
        "K":glyph=56'h666c7870786c66;"L":glyph=56'h6060606060607e;
        "M":glyph=56'h63777f6b636363;"N":glyph=56'h6676766e6e6666;
        "O":glyph=56'h3c66666666663c;"P":glyph=56'h7c66667c606060;
        "Q":glyph=56'h3c6666666a6c36;"R":glyph=56'h7c66667c786c66;
        "S":glyph=56'h3c66603c06663c;"T":glyph=56'h7e181818181818;
        "U":glyph=56'h6666666666663c;"V":glyph=56'h66666666663c18;
        "W":glyph=56'h6363636b7f7763;"X":glyph=56'h66663c183c6666;
        "Y":glyph=56'h6666663c181818;"Z":glyph=56'h7e060c1830607e;
        "-":glyph=56'h0000007e000000;".":glyph=56'h00000000001818;
        ":":glyph=56'h00181800181800;"/":glyph=56'h02060c18306040;
        "_":glyph=56'h0000000000007e;"!":glyph=56'h18181818180018;
        "?":glyph=56'h3c66060c180018;" ":glyph=0;
        default:glyph=56'h7e42424242427e;
    endcase
    assign bitmap=row<7?(glyph>>((6-row)*8)):8'b0;
endmodule
