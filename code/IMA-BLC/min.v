`timescale 1ns / 1ps
module min #(
    parameter DATA_WIDTH = 8
)(
    input [3*DATA_WIDTH-1:0] data,
    output [DATA_WIDTH-1:0] min
    );
    
    wire [DATA_WIDTH-1:0] a,b,c;
    wire [DATA_WIDTH-1:0] temp_min;
    
    assign a = data[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign b = data[2*DATA_WIDTH-1:1*DATA_WIDTH];
    assign c = data[1*DATA_WIDTH-1:0*DATA_WIDTH];
    
    assign temp_min = a < b ? a : b;
    assign min = temp_min < c ? temp_min : c; 
endmodule
