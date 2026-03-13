/*
   Ajax3d - a 3d engine using the WHATWG HTML <canvas> tag.
   
   Copyright (C) 2007 Eben Upton
   
   This program is free software; you can redistribute it and/or
   modify it under the terms of version 2 of the GNU General Public 
   License as published by the Free Software Foundation.
   
   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.
   
   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

var lander_material_pink       = {ambient: [0.5, 0.0, 0.5], diffuse: [0.5, 0.0, 0.5], specular: [1.0, 1.0, 1.0], phong: 4.0};
var lander_material_purple     = {ambient: [0.3, 0.0, 0.5], diffuse: [0.3, 0.0, 0.5], specular: [1.0, 1.0, 1.0], phong: 4.0};
var lander_material_darkpurple = {ambient: [0.1, 0.0, 0.3], diffuse: [0.2, 0.0, 0.4], specular: [1.0, 1.0, 1.0], phong: 4.0};

var lander_material_green      = {ambient: [0.0, 0.3, 0.0], diffuse: [0.3, 0.8, 0.3], specular: [0.0, 0.0, 0.0], phong: 1.0};
var lander_material_brown      = {ambient: [0.2, 0.1, 0.0], diffuse: [0.4, 0.2, 0.0], specular: [0.0, 0.0, 0.0], phong: 1.0};

var lander_model_ship = {vertices: [[[-0.6,  0.0, -0.5,  1.0],
                                     [ 0.6,  0.0, -0.5,  1.0],
                                     [ 0.3,  0.0,  0.5,  1.0],
                                     [-0.3,  0.0,  0.5,  1.0],
                                     [-0.2, -0.4, -0.5,  1.0],
                                     [ 0.2, -0.4, -0.5,  1.0]]],
                         faces: [{indices: [0, 1, 2, 3], material: lander_material_darkpurple, clip: 0},
                                 {indices: [4, 3, 2, 5], material: lander_material_purple, clip: 0},
                                 {indices: [0, 4, 5, 1], material: lander_material_purple, clip: 0},
                                 {indices: [4, 0, 3], material: lander_material_pink, clip: 0},
                                 {indices: [1, 5, 2], material: lander_material_pink, clip: 0}],
                         bias: -0.04};

j3d_model_make_normals(lander_model_ship);
j3d_model_make_centers(lander_model_ship);

const alien1_a = 0.8;
const alien1_b = alien1_a * Math.sin(Math.PI / 4);
const alien1_c = 0.4;

var lander_model_alien1 = {vertices: [[[      0.0,       0.0, -alien1_a,  1.0],
                                       [ alien1_b,       0.0, -alien1_b,  1.0],
                                       [ alien1_a,       0.0,       0.0,  1.0],
                                       [ alien1_b,       0.0,  alien1_b,  1.0],
                                       [      0.0,       0.0,  alien1_a,  1.0],
                                       [-alien1_b,       0.0,  alien1_b,  1.0],
                                       [-alien1_a,       0.0,       0.0,  1.0],
                                       [-alien1_b,       0.0, -alien1_b,  1.0],
                                       [      0.0, -alien1_c,       0.0,  1.0],
                                       [      0.0,  alien1_c,       0.0,  1.0]]],
                           faces: [{indices: [0, 8, 1], material: lander_material_purple},
                                   {indices: [1, 8, 2], material: lander_material_pink},
                                   {indices: [2, 8, 3], material: lander_material_purple},
                                   {indices: [3, 8, 4], material: lander_material_pink},
                                   {indices: [4, 8, 5], material: lander_material_purple},
                                   {indices: [5, 8, 6], material: lander_material_pink},
                                   {indices: [6, 8, 7], material: lander_material_purple},
                                   {indices: [7, 8, 0], material: lander_material_pink},
                                   {indices: [1, 9, 0], material: lander_material_pink},
                                   {indices: [2, 9, 1], material: lander_material_purple},
                                   {indices: [3, 9, 2], material: lander_material_pink},
                                   {indices: [4, 9, 3], material: lander_material_purple},
                                   {indices: [5, 9, 4], material: lander_material_pink},
                                   {indices: [6, 9, 5], material: lander_material_purple},
                                   {indices: [7, 9, 6], material: lander_material_pink},
                                   {indices: [0, 9, 7], material: lander_material_purple}]};

j3d_model_make_normals(lander_model_alien1);
j3d_model_make_centers(lander_model_alien1);

const tree_a = 0.2;
const tree_b = tree_a * Math.sin(Math.PI / 6);
const tree_c = tree_a * Math.cos(Math.PI / 6);

const tree_d = 0.5;
const tree_e = tree_d * Math.sin(Math.PI / 6);
const tree_f = tree_d * Math.cos(Math.PI / 6);

const tree_g = 0.2;
const tree_h = tree_g + 1.5;

var lander_model_tree = {vertices: [[[    0.0,     0.0,  tree_a,  1.0],
                                     [-tree_c,     0.0, -tree_b,  1.0],
                                     [ tree_c,     0.0, -tree_b,  1.0],
                                     [    0.0, -tree_g,  tree_a,  1.0],
                                     [-tree_c, -tree_g, -tree_b,  1.0],
                                     [ tree_c, -tree_g, -tree_b,  1.0],
                                     [    0.0, -tree_g,  tree_d,  1.0],
                                     [-tree_f, -tree_g, -tree_e,  1.0],
                                     [ tree_f, -tree_g, -tree_e,  1.0],
                                     [    0.0, -tree_h,     0.0,  1.0]]],
                         faces: [{indices: [0, 3, 4, 1], material: lander_material_brown, clip: 0},
                                 {indices: [1, 4, 5, 2], material: lander_material_brown, clip: 0},
                                 {indices: [2, 5, 3, 0], material: lander_material_brown, clip: 0},
                                 {indices: [6, 9, 7], material: lander_material_green, bias: -0.02, clip: 0},
                                 {indices: [7, 9, 8], material: lander_material_green, bias: -0.02, clip: 0},
                                 {indices: [8, 9, 6], material: lander_material_green, bias: -0.02, clip: 0}],
                         bias: -0.02};

j3d_model_make_normals(lander_model_tree);
j3d_model_make_centers(lander_model_tree);

const debris_a = 0.4;
const debris_b = debris_a * Math.sin(Math.PI / 6);
const debris_c = debris_a * Math.cos(Math.PI / 6);

var lander_model_debris = {vertices: [[[    0.0,     0.0,  debris_a,  1.0],
                                       [-debris_c,     0.0, -debris_b,  1.0],
                                       [ debris_c,     0.0, -debris_b,  1.0]]],
                           faces: [{indices: [0, 1, 2], material: lander_material_pink},
                                   {indices: [0, 2, 1], material: lander_material_purple}]};

j3d_model_make_normals(lander_model_debris);
j3d_model_make_centers(lander_model_debris);
