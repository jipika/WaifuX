const _Epsilon = 0.00001;
class Vec2 {
	constructor(x,y){
		if(typeof x === 'string'){
			x=x.split(' ');
			this.x=parseFloat(x[0]);
			this.y=parseFloat(x[1]);
		}else if(x instanceof Vec3){
			this.x=x.x;
			this.y=x.y;
		}else if(x instanceof Vec2){
			this.x=x.x;
			this.y=x.y;
		}else if(typeof x!=='undefined'){
			this.x=x;
			this.y=(typeof y==='number')?y:x;
		}else{
			this.x=this.y=0;
		}
	}
	length(){
		return Math.sqrt(this.x*this.x+this.y*this.y);
	}
	lengthSqr(){
		return this.x*this.x+this.y*this.y;
	}
	normalize(){
		return this.divide(this.length());
	}
	copy(){
		return new Vec2(
			this.x,
			this.y
		);
	}
	equals(f){
		if (typeof f !== 'Vec2') { return false; }
		return Math.abs(this.x-f.x) < _Epsilon &&
			Math.abs(this.y-f.y) < _Epsilon;
	}
	add(f){
		if(typeof f === 'number'){
			return new Vec2(
				this.x+f,
				this.y+f
			);
		}else{
			return new Vec2(
				this.x+f.x,
				this.y+f.y
			);
		}
	}
	subtract(f){
		if(typeof f === 'number'){
			return new Vec2(
				this.x-f,
				this.y-f
			);
		}else{
			return new Vec2(
				this.x-f.x,
				this.y-f.y
			);
		}
	}
	multiply(f){
		if(typeof f === 'number'){
			return new Vec2(
				this.x*f,
				this.y*f
			);
		}else{
			return new Vec2(
				this.x*f.x,
				this.y*f.y
			);
		}
	}
	divide(f){
		if(typeof f === 'number'){
			return new Vec2(
				this.x/f,
				this.y/f
			);
		}else{
			return new Vec2(
				this.x/f.x,
				this.y/f.y
			);
		}
	}
	dot(f){
		return this.x*f.x+this.y*f.y;
	}
	reflect(f){
		return this.subtract(f.multiply(2*this.dot(f)));
	}
	perpendicular(){
		return new Vec2(this.y, -this.x);
	}
	mix(v, a){
		if(typeof a === 'number'){
			return new Vec2(
				this.x+(v.x-this.x)*a,
				this.y+(v.y-this.y)*a
			);
		}else{
			return new Vec2(
				this.x+(v.x-this.x)*a.x,
				this.y+(v.y-this.y)*a.y
			);
		}
	}
	min(v){
		return new Vec2(
			Math.min(this.x, v.x),
			Math.min(this.y, v.y)
		);
	}
	max(v){
		return new Vec2(
			Math.max(this.x, v.x),
			Math.max(this.y, v.y)
		);
	}
	abs(){
		return new Vec2(Math.abs(this.x), Math.abs(this.y));
	}
	sign(){
		return new Vec2(Math.sign(this.x), Math.sign(this.y));
	}
	round(){
		return new Vec2(Math.round(this.x), Math.round(this.y));
	}
	floor(){
		return new Vec2(Math.floor(this.x), Math.floor(this.y));
	}
	ceil(){
		return new Vec2(Math.ceil(this.x), Math.ceil(this.y));
	}
	//smoothStep(min, max) {
	//	let x = Math.max(0, Math.min(1, (this.x-min.x)/(max.x-min.x)));
	//	let y = Math.max(0, Math.min(1, (this.y-min.y)/(max.y-min.y)));
	//	return new Vec2(x*x*(3-2*x), y*y*(3-2*y));
	//}
	toString(){
		return this.x+' '+this.y;
	}
	toJSONString(){
		return this.toString();
	}
}
class Vec3{
	constructor(x,y,z){
		if(typeof x === 'string'){
			x=x.split(' ');
			this.x=parseFloat(x[0]);
			this.y=parseFloat(x[1]);
			this.z=parseFloat(x[2]);
		}else if(x instanceof Vec3){
			this.x=x.x;
			this.y=x.y;
			this.z=x.z;
		}else if(x instanceof Vec2){
			this.x=x.x;
			this.y=x.y;
			this.z=0;
		}else if(typeof x!=='undefined'){
			this.x=x;
			this.y=(typeof y==='number')?y:x;
			this.z=(typeof z==='number')?z:((typeof y==='number')?0:x);
		}else{
			this.x=this.y=this.z=0;
		}
	}
	length(){
		return Math.sqrt(this.x*this.x+this.y*this.y+this.z*this.z);
	}
	lengthSqr(){
		return this.x*this.x+this.y*this.y+this.z*this.z;
	}
	normalize(){
		return this.divide(this.length());
	}
	copy(){
		return new Vec3(
			this.x,
			this.y,
			this.z
		);
	}
	equals(f){
		if (typeof f !== 'Vec3') { return false; }
		return Math.abs(this.x-f.x) < _Epsilon &&
			Math.abs(this.y-f.y) < _Epsilon &&
			Math.abs(this.z-f.z) < _Epsilon;
	}
	add(f){
		if(typeof f === 'number'){
			return new Vec3(
				this.x+f,
				this.y+f,
				this.z+f
			);
		}else if(f instanceof Vec2){
			return new Vec3(
				this.x+f.x,
				this.y+f.y,
				this.z
			);
		}else{
			return new Vec3(
				this.x+f.x,
				this.y+f.y,
				this.z+f.z
			);
		}
	}
	subtract(f){
		if(typeof f === 'number'){
			return new Vec3(
				this.x-f,
				this.y-f,
				this.z-f
			);
		}else if(f instanceof Vec2){
			return new Vec3(
				this.x-f.x,
				this.y-f.y,
				this.z
			);
		}else{
			return new Vec3(
				this.x-f.x,
				this.y-f.y,
				this.z-f.z
			);
		}
	}
	multiply(f){
		if(typeof f === 'number'){
			return new Vec3(
				this.x*f,
				this.y*f,
				this.z*f
			);
		}else if(f instanceof Vec2){
			return new Vec3(
				this.x*f.x,
				this.y*f.y,
				this.z
			);
		}else{
			return new Vec3(
				this.x*f.x,
				this.y*f.y,
				this.z*f.z
			);
		}
	}
	divide(f){
		if(typeof f === 'number'){
			return new Vec3(
				this.x/f,
				this.y/f,
				this.z/f
			);
		}else if(f instanceof Vec2){
			return new Vec3(
				this.x/f.x,
				this.y/f.y,
				this.z
			);
		}else{
			return new Vec3(
				this.x/f.x,
				this.y/f.y,
				this.z/f.z
			);
		}
	}
	cross(f){
		return new Vec3(
			this.y*f.z-this.z*f.y,
			this.z*f.x-this.x*f.z,
			this.x*f.y-this.y*f.x
		);
	}
	dot(f){
		return this.x*f.x+this.y*f.y+this.z*f.z;
	}
	reflect(f){
		return this.subtract(f.multiply(2*this.dot(f)));
	}
	mix(v, a){
		if(typeof a === 'number'){
			return new Vec3(
				this.x+(v.x-this.x)*a,
				this.y+(v.y-this.y)*a,
				this.z+(v.z-this.z)*a
			);
		}else{
			return new Vec3(
				this.x+(v.x-this.x)*a.x,
				this.y+(v.y-this.y)*a.y,
				this.z+(v.z-this.z)*a.z
			);
		}
	}
	min(v){
		return new Vec3(
			Math.min(this.x, v.x),
			Math.min(this.y, v.y),
			Math.min(this.z, v.z)
		);
	}
	max(v){
		return new Vec3(
			Math.max(this.x, v.x),
			Math.max(this.y, v.y),
			Math.max(this.z, v.z)
		);
	}
	abs(){
		return new Vec3(Math.abs(this.x), Math.abs(this.y), Math.abs(this.z));
	}
	sign(){
		return new Vec3(Math.sign(this.x), Math.sign(this.y), Math.sign(this.z));
	}
	round(){
		return new Vec3(Math.round(this.x), Math.round(this.y), Math.round(this.z));
	}
	floor(){
		return new Vec3(Math.floor(this.x), Math.floor(this.y), Math.floor(this.z));
	}
	ceil(){
		return new Vec3(Math.ceil(this.x), Math.ceil(this.y), Math.ceil(this.z));
	}
	//smoothStep(min, max) {
	//	let x = Math.max(0, Math.min(1, (this.x-min.x)/(max.x-min.x)));
	//	let y = Math.max(0, Math.min(1, (this.y-min.y)/(max.y-min.y)));
	//	let z = Math.max(0, Math.min(1, (this.z-min.z)/(max.z-min.z)));
	//	return new Vec3(x*x*(3-2*x), y*y*(3-2*y), z*z*(3-2*z));
	//}
	toString(){
		return this.x+' '+this.y+' '+this.z;
	}
	toJSONString(){
		return this.toString();
	}
}
class Vec4 {
	constructor(x,y,z,w){
		if(typeof x === 'string'){
			x=x.split(' ');
			this.x=parseFloat(x[0]);
			this.y=parseFloat(x[1]);
			this.z=parseFloat(x[2]);
			this.w=parseFloat(x[3]);
		}else if(x instanceof Vec4){
			this.x=x.x;
			this.y=x.y;
			this.z=x.z;
			this.w=x.w;
		}else if(x instanceof Vec3){
			this.x=x.x;
			this.y=x.y;
			this.z=x.z;
			this.w=0;
		}else if(x instanceof Vec2){
			this.x=x.x;
			this.y=x.y;
			this.z=0;
			this.w=0;
		}else if(typeof x!=='undefined'){
			this.x=x;
			this.y=(typeof y==='number')?y:x;
			this.z=(typeof z==='number')?z:((typeof y==='number')?0:x);
			this.w=(typeof w==='number')?w:((typeof z==='number')?z:((typeof y==='number')?0:x));
		}else{
			this.x=this.y=this.z=this.w=0;
		}
	}
	toString(){
		return this.x+' '+this.y+' '+this.z+' '+this.w;
	}
	toJSONString(){
		return this.toString();
	}
}
class Mat4 {
	constructor(){
		this.m = [1, 0, 0, 0,
				0, 1, 0, 0,
				0, 0, 1, 0,
				0, 0, 0, 1];
	}
	toString(){
		return this.m[0]+' '+this.m[1]+' '+this.m[2]+' '+this.m[3]+' '+
				this.m[4]+' '+this.m[5]+' '+this.m[6]+' '+this.m[7]+' '+
				this.m[8]+' '+this.m[9]+' '+this.m[10]+' '+this.m[11]+' '+
				this.m[12]+' '+this.m[13]+' '+this.m[14]+' '+this.m[15];
	}
	translation(v){
		if(v instanceof Vec3){
			this.m[12]=v.x;
			this.m[13]=v.y;
			this.m[14]=v.z;
			return this;
		}else if(v instanceof Vec2){
			this.m[12]=v.x;
			this.m[13]=v.y;
			this.m[14]=0;
			return this;
		}else{
			return new Vec3(this.m[12], this.m[13], this.m[14]);
		}
	}
	right(){
		return new Vec3(this.m[0], this.m[1], this.m[2]);
	}
	up(){
		return new Vec3(this.m[4], this.m[5], this.m[6]);
	}
	forward(){
		return new Vec3(this.m[8], this.m[9], this.m[10]);
	}
	toJSONString(){
		return this.toString();
	}
}
class Mat3 {
	constructor(){
		this.m = [1, 0, 0,
				0, 1, 0,
				0, 0, 1];
	}
	toString(){
		return this.m[0]+' '+this.m[1]+' '+this.m[2]+' '
				this.m[3]+' '+this.m[4]+' '+this.m[5]+' '
				this.m[6]+' '+this.m[7]+' '+this.m[8];
	}
	translation(v){
		if(v instanceof Vec2){
			this.m[6]=v.x;
			this.m[7]=v.y;
			return this;
		}else{
			return new Vec2(this.m[6], this.m[7]);
		}
	}
	angle(){
		return Math.atan2(this.m[0], -this.m[1]) * (180.0 / Math.PI);
	}
	toJSONString(){
		return this.toString();
	}
}
class MediaPlaybackEvent {
	static PLAYBACK_STOPPED = 0
	static PLAYBACK_PLAYING = 1
	static PLAYBACK_PAUSED = 2
}
function stringifyAdapter(key, value){
	if (value && value.toJSONString){
		return value.toJSONString();
	}
	return value;
}
this._Vec2 = Vec2.prototype;
this._Vec3 = Vec3.prototype;
this._Vec4 = Vec4.prototype;
this._Mat4 = Mat4.prototype;
this._Mat3 = Mat3.prototype;
this._Internal = {
	updateScriptProperties(script, vars) {
		vars = JSON.parse(vars);
		Object.keys(vars).forEach((key) => {
			if (script.scriptProperties.hasOwnProperty(key)) {
				if (script.scriptProperties[key] instanceof Vec3){
					script.scriptProperties[key] = new Vec3(vars[key]);
				} else {
					script.scriptProperties[key] = vars[key];
				}
			}
		});
	},
	convertUserProperties(p) {
		p = JSON.parse(p);
		let r = {};
		for (var k in p) {
			switch (p[k].type){
			default:
				r[k] = p[k].value;
				break;
			case 'usershortcut':
				r[k] = {isbound: p[k].isbound, commandtype: p[k].commandtype, file:p[k].file};
				break;
			case 'color':
				r[k] = new Vec3(p[k].value);
				break;
			}
		}
		return r;
	},
	stringifyConfig(obj) {
		return JSON.stringify(obj, stringifyAdapter);
	}
};
this.createScriptProperties=function(){
	var vars={};
	var obj = {
		order: 0,
		addSlider: function(options){
			vars[options.name] = options.value;
			vars[options.name + '_config'] = { order: obj.order++, label: options.label,
				min: options.min, max: options.max, mode: (options.integer===true)?'int':undefined };
			return obj;
		},
		addCheckbox: function(options){
			vars[options.name] = options.value;
			vars[options.name + '_config'] = { order: obj.order++, label: options.label };
			return obj;
		},
		addText: function(options){
			vars[options.name] = options.value;
			vars[options.name + '_config'] = { order: obj.order++, label: options.label };
			return obj;
		},
		addCombo: function(options){
			vars[options.name] = options.options[0].value;
			vars[options.name + '_config'] = { order: obj.order++, label: options.label, options: options.options, mode: 'combo' };
			return obj;
		},
		addColor: function(options){
			vars[options.name] = options.value;
			vars[options.name + '_config'] = { order: obj.order++, label: options.label };
			return obj;
		},
		finish: function(){return vars;}
	};
	return obj;
}
this.shared = {};
