mat3 BuildTangentSpace(const vec3 normal, const vec4 signedTangent)
{
	vec3 tangent = signedTangent.xyz;
	vec3 bitangent = cross(normal, tangent) * signedTangent.w;
	return mat3(tangent, bitangent, normal);
}

mat3 BuildTangentSpace(const mat3 modelTransform, const vec3 normal, const vec4 signedTangent)
{
	vec3 tangent = signedTangent.xyz;
	vec3 bitangent = cross(normal, tangent) * signedTangent.w;
	return mat3(mul(tangent, modelTransform),
		mul(bitangent, modelTransform),
		mul(normal, modelTransform));
}