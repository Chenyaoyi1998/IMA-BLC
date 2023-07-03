`timescale 1ns / 1ps
module max #(
    parameter DATA_WIDTH = 8
)(
    input [3*DATA_WIDTH-1:0] data,
    output [DATA_WIDTH-1:0] max
    );
    
    wire [DATA_WIDTH-1:0] a,b,c;
    wire [DATA_WIDTH-1:0] temp_max;
    
    assign a = data[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign b = data[2*DATA_WIDTH-1:1*DATA_WIDTH];
    assign c = data[1*DATA_WIDTH-1:0*DATA_WIDTH];
    
    assign temp_max = a > b ? a : b;
    assign max = temp_max > c ? temp_max : c; 
endmodule
