
mat3 squareToQuad(vec2 p0, vec2 p1, vec2 p2, vec2 p3) {
	mat3 m = mat3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
	float dx0 = p0.x;
	float dy0 = p0.y;
	float dx1 = p1.x;
	float dy1 = p1.y;
	
	float dx2 = p3.x;
	float dy2 = p3.y;
	float dx3 = p2.x;
	float dy3 = p2.y;
	
	float diffx1 = dx1 - dx3;
	float diffy1 = dy1 - dy3;
	float diffx2 = dx2 - dx3;
	float diffy2 = dy2 - dy3;

	float det = diffx1*diffy2 - diffx2*diffy1;
	float sumx = dx0 - dx1 + dx3 - dx2;
	float sumy = dy0 - dy1 + dy3 - dy2;

	if (det == 0.0 || (sumx == 0.0 && sumy == 0.0)) {
		m[0][0] = dx1 - dx0;
		m[0][1] = dy1 - dy0;
		m[0][2] = 0.0;
		m[1][0] = dx3 - dx1;
		m[1][1] = dy3 - dy1;
		m[1][2] = 0.0;
		m[2][0] = dx0;
		m[2][1] = dy0;
		m[2][2] = 1.0;
		return m;
	} else {
		float ovdet = 1.0 / det;
		float g = (sumx * diffy2 - diffx2 * sumy) * ovdet;
		float h = (diffx1 * sumy - sumx * diffy1) * ovdet;

		m[0][0] = dx1 - dx0 + g * dx1;
		m[0][1] = dy1 - dy0 + g * dy1;
		m[0][2] = g;
		m[1][0] = dx2 - dx0 + h * dx2;
		m[1][1] = dy2 - dy0 + h * dy2;
		m[1][2] = h;
		m[2][0] = dx0;
		m[2][1] = dy0;
		m[2][2] = 1.0;
		return m;
	}
}

#if HLSL
mat3 inverse(mat3 m) {
	float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2];
	float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2];
	float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2];
	float b01 = a22 * a11 - a12 * a21;
	float b11 = -a22 * a10 + a12 * a20;
	float b21 = a21 * a10 - a11 * a20;
	float det = a00 * b01 + a01 * b11 + a02 * b21;
	return mat3(b01, (-a22 * a01 + a02 * a21), (a12 * a01 - a02 * a11),
			  b11, (a22 * a00 - a02 * a20), (-a12 * a00 + a02 * a10),
			  b21, (-a21 * a00 + a01 * a20), (a11 * a00 - a01 * a10)) / det;
}
#endif
