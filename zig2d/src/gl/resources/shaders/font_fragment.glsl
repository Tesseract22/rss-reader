#version 330 core
out vec4 FragColor;

in vec4 vertexColor;
in vec2 texCoord;

uniform sampler2D text;

void main() {
    vec4 texColor  = texture(text, texCoord);
    FragColor = vec4(vertexColor.rgb, vertexColor.a * texColor.a);
}
