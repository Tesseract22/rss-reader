#version 330 core
layout (location = 0) in vec3 pos;
layout (location = 1) in vec3 rgb;
layout (location = 2) in vec2 tex;

out vec4 vertexColor;
out vec2 texCoord;


void main() {
    gl_Position = vec4(pos, 1.0);
    vertexColor = vec4(rgb, 1.0);
    texCoord = tex;
}
