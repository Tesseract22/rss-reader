#version 330 core
out vec4 FragColor;

in vec4 vertexColor;
in vec2 texCoord;

uniform sampler2D tex;

void main() {
    // FragColor = texture(tex, texCoord) * vertexColor;
    vec4 texColor  = texture(tex, texCoord);
    FragColor = vec4(vertexColor.rgb, vertexColor.a * texColor.a);
    // FragColor = vertexColor;
}
