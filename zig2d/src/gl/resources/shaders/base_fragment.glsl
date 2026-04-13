#version 330 core
out vec4 FragColor;

in vec4 vertexColor;
in vec2 texCoord;

uniform sampler2D tex;

void main() {
    vec4 texColor  = texture(tex, texCoord);
    FragColor = texColor * vertexColor;
    // FragColor = vertexColor;
}
