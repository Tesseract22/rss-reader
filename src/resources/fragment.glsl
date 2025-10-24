#version 330 core
out vec4 FragColor;
in vec4 vertexColor;
in vec2 tex_coord;

void main() {
    vec2 p = (tex_coord - vec2(0.5, 0.5)) * 2;
    float dist = sqrt(p.x*p.x + p.y*p.y);
    // float glow = 2-exp(l);
    // float glow = 1-sqrt(l);
    if (dist < 1.4) 
	FragColor = vec4(vertexColor.rgb, vertexColor.a);
    else
	FragColor = vec4(vertexColor.rgb, 0);
}
