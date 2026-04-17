'use strict';

export let deg2rad = Math.PI / 180;
export let rad2deg = 180 / Math.PI;

export function smoothStep(min, max, v) {
	let x = Math.max(0, Math.min(1, (v-min)/(max-min)));
	return x*x*(3-2*x);
};

export function mix(a, b, v) {
	return a+(b-a)*v;
};
