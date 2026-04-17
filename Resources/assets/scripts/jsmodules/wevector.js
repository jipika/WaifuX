'use strict';

import * as WEMath from 'WEMath';

export function angleVector2(angle) {
	angle = angle * WEMath.deg2rad;
	return new Vec2(
		Math.cos(angle),
		Math.sin(angle)
	);
}

export function vectorAngle2(direction) {
	return Math.atan2(direction.y, direction.x) * WEMath.rad2deg;
}
