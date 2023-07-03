`timescale 1ns / 1ps
module comparator_w #(
    parameter DATA_WIDTH = 8
) (
    input [3*DATA_WIDTH-1:0] data_befor,
    output [DATA_WIDTH-1:0] max,med,min
    );
    
    wire [DATA_WIDTH-1:0] a,b,c;
    wire [DATA_WIDTH-1:0] temp_max, temp_min, temp_med;
    
    assign a = data_befor[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign b = data_befor[2*DATA_WIDTH-1:1*DATA_WIDTH];
    assign c = data_befor[1*DATA_WIDTH-1:0*DATA_WIDTH];
    assign {temp_max, temp_min} = a > b ? {a,b} : {b,a};
    assign {temp_med,min} = temp_min < c ? {c,temp_min} : {temp_min,c};
    assign {max,med} = temp_max > temp_med ? {temp_max, temp_med} : {temp_med, temp_max};
endmodule
