use crate::Context;
use crate::game::{QuadFlags, SpriteKind, ZLayer};
use crate::gsh;
use crate::utils::{Matrix4, Timer, Vec2, Vec3, Vec4};
use image::{ImageBuffer, Rgba};
use rusttype::{Font as RFont, Scale, point};
use sokol::{
    app::{self as sapp, android_get_native_activity},
    gfx as sg, glue as sglue, log as slog,
};
use stb_image::stb_image as stbi;
use stb_rect_pack_sys as stbrp;
use std::fs;
use strum::IntoEnumIterator;

const MAX_QUADS: u32 = 8192;
const MAX_VERTS: u32 = MAX_QUADS * 4;
const DEFAULT_UV: Vec4 = Vec4 {
    x: 0.0,
    y: 0.0,
    z: 1.0,
    w: 1.0,
};

#[derive(Clone)]
pub struct RenderContext {
    pub pa: sg::PassAction,
    pub pp: sg::Pipeline,
    pub bind: sg::Bindings,
    pub quad_data: [u8; (MAX_QUADS as usize * size_of::<Quad>())],
    pub timer: Timer,
    pub delta_t: f64,
    pub last_frame_time: f64,
    pub draw_frame: DrawFrame,
}

pub type Quad = [Vertex; 4];

#[derive(Clone)]
pub struct Vertex {
    pos: Vec2,
    col: Vec4,
    uv: Vec2,
    local_uv: Vec2,
    size: Vec2,
    tex_index: u8,
    z_layer: u8,
    quad_flags: crate::game::QuadFlags,
    col_override: Vec4,
    params: Vec4,
}

pub fn init(ctx: &mut Context) {
    sg::setup(&sg::Desc {
        environment: sglue::environment(),
        logger: sg::Logger {
            func: Some(slog::slog_func),
            ..Default::default()
        },
        ..Default::default()
    });

    build_atlas(ctx);
    load_font(ctx); // TODO: add moar fonts

    ctx.render.bind.vertex_buffers[0] = sg::make_buffer(&sg::BufferDesc {
        size: size_of_val(&ctx.render.quad_data),
        usage: sg::BufferUsage {
            stream_update: true,
            vertex_buffer: true,
            ..Default::default()
        },
        ..Default::default()
    });

    let index_buffer_count = MAX_QUADS * 6;
    let mut indices: Vec<u16> = Vec::with_capacity(index_buffer_count as usize);
    indices.resize(index_buffer_count as usize, 0);

    let mut i: u32 = 0;
    while (i < index_buffer_count) {
        indices[(i + 0) as usize] = ((i / 6) * 4 + 0) as u16;
        indices[(i + 1) as usize] = ((i / 6) * 4 + 1) as u16;
        indices[(i + 2) as usize] = ((i / 6) * 4 + 2) as u16;
        indices[(i + 3) as usize] = ((i / 6) * 4 + 0) as u16;
        indices[(i + 4) as usize] = ((i / 6) * 4 + 2) as u16;
        indices[(i + 5) as usize] = ((i / 6) * 4 + 3) as u16;
        i += 6;
    }

    ctx.render.bind.index_buffer = sg::make_buffer(&sg::BufferDesc {
        data: sg::Range {
            ptr: indices.as_ptr() as *const std::ffi::c_void,
            size: size_of::<u16>() * index_buffer_count as usize,
        },
        usage: sg::BufferUsage {
            index_buffer: true,
            ..Default::default()
        },
        ..Default::default()
    });

    // image stuff
    ctx.render.bind.samplers[gsh::SMP_DEFAULT_SAMPLER] =
        sg::make_sampler(&sg::SamplerDesc::default());

    // setup pp
    let mut desc = sg::PipelineDesc {
        shader: sg::make_shader(&gsh::quad_shader_desc(sg::query_backend())),
        index_type: sg::IndexType::Uint16,
        layout: sg::VertexLayoutState {
            attrs: {
                let mut attrs = [sg::VertexAttrState::default(); sg::MAX_VERTEX_ATTRIBUTES];
                attrs[gsh::ATTR_QUAD_POSITION as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float2,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_COLOR0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float4,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_UV0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float2,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_LOCAL_UV0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float2,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_SIZE0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float2,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_BYTES0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Ubyte4n,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_COLOR_OVERRIDE0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float4,
                    ..Default::default()
                };
                attrs[gsh::ATTR_QUAD_PARAMS0 as usize] = sg::VertexAttrState {
                    format: sg::VertexFormat::Float4,
                    ..Default::default()
                };
                attrs
            },
            ..Default::default()
        },
        ..Default::default()
    };

    let blend_state = sg::BlendState {
        enabled: true,
        src_factor_rgb: sg::BlendFactor::SrcAlpha,
        dst_factor_rgb: sg::BlendFactor::OneMinusSrcAlpha,
        op_rgb: sg::BlendOp::Add,
        src_factor_alpha: sg::BlendFactor::One,
        dst_factor_alpha: sg::BlendFactor::OneMinusSrcAlpha,
        op_alpha: sg::BlendOp::Add,
    };

    desc.colors[0] = sg::ColorTargetState {
        blend: blend_state,
        ..Default::default()
    };

    ctx.render.pp = sg::make_pipeline(&desc);
    let mut colors = [sg::ColorAttachmentAction::default(); 8];
    colors[0] = sg::ColorAttachmentAction {
        load_action: sg::LoadAction::Clear,
        clear_value: sg::Color {
            r: 1.0,
            g: 1.0,
            b: 1.0,
            a: 1.0,
        },
        ..Default::default()
    };

    ctx.render.pa = sg::PassAction {
        colors: colors,
        ..Default::default()
    }
}

#[derive(Clone)]
pub struct DrawFrame {
    pub quads: Vec<Vec<Quad>>,
    pub coord_space: CoordSpace,
    pub active_zlayer: ZLayer,
    pub active_flags: QuadFlags,
    pub shader_data: gsh::ShaderData,
}

impl Default for crate::gsh::ShaderData {
    fn default() -> Self {
        crate::gsh::ShaderData {
            ndc_to_world_xform: crate::utils::Matrix4::default(),
            bg_repeat_tex0_atlas_uv: crate::utils::Vec4::new(0.0, 0.0, 0.0, 0.0),
        }
    }
}

impl Default for DrawFrame {
    fn default() -> Self {
        DrawFrame {
            quads: Vec::new(),
            coord_space: CoordSpace::default(),
            active_zlayer: ZLayer::nil,
            active_flags: QuadFlags::empty(),
            shader_data: crate::gsh::ShaderData::default(),
        }
    }
}

impl Clone for crate::gsh::ShaderData {
    fn clone(&self) -> Self {
        Self {
            ndc_to_world_xform: self.ndc_to_world_xform.clone(),
            bg_repeat_tex0_atlas_uv: self.bg_repeat_tex0_atlas_uv.clone(),
        }
    }
}

#[derive(Clone)]
pub struct CoordSpace {
    proj: Matrix4,
    camera: Matrix4,
}

impl Default for CoordSpace {
    fn default() -> Self {
        CoordSpace {
            proj: Matrix4::default(),
            camera: Matrix4::default(),
        }
    }
}

pub fn core_start_frame(ctx: &mut Context) {
    // Reset draw frame
    ctx.render.draw_frame = DrawFrame::default();

    ctx.render.draw_frame.quads[ZLayer::bg as usize] = Vec::with_capacity(512);
    ctx.render.draw_frame.quads[ZLayer::shadow as usize] = Vec::with_capacity(128);
    ctx.render.draw_frame.quads[ZLayer::playspace as usize] = Vec::with_capacity(256);
    ctx.render.draw_frame.quads[ZLayer::tooltip as usize] = Vec::with_capacity(256);
}

pub fn core_end_frame(ctx: &mut Context) {
    let mut quad_count: u32 = 0;

    for layer in &ctx.render.draw_frame.quads {
        quad_count += layer.len() as u32;
    }

    assert!(quad_count <= MAX_QUADS, "Too many rectangles!");
}

const IMG_DIR: &str = "beans/images/";
const ATLAS_SIZE: u32 = 1024;

#[derive(Clone)]
pub struct Sprite {
    pub width: i32,
    pub height: i32,
    pub tex_index: u8,
    pub sg_img: sg::Image,
    pub data: Vec<u8>,
    pub atlas_uvs: Vec4,
}

#[derive(Clone)]
pub struct Atlas {
    pub w: u32,
    pub h: u32,
    pub sg_image: sg::Image,
    pub sg_view: sg::View,
}

fn build_atlas(ctx: &mut Context) -> Result<(), std::io::Error> {
    for kind in SpriteKind::iter() {
        if kind == SpriteKind::nil {
            continue;
        };

        let path = format!("{}{:?}.png", IMG_DIR, kind);
        let png_data = std::fs::read(path.clone())
            .unwrap_or_else(|_| panic!("Failed to read file: '{}'. Does it exist?", path));

        // eww
        unsafe {
            stbi::stbi_set_flip_vertically_on_load(1);
        }

        let mut width: i32 = 0;
        let mut height: i32 = 0;
        let mut channels: i32 = 0;

        let img_data = unsafe {
            stbi::stbi_load_from_memory(
                png_data.as_ptr(),
                png_data.len() as i32,
                &mut width as *mut i32,
                &mut height as *mut i32,
                &mut channels as *mut i32,
                4,
            )
        };

        if img_data.is_null() {
            panic!("Failed to load image from memory for file: {}", path);
        }

        let size = (width * height * 4) as usize;

        let sprite = Sprite {
            width: width,
            height: height,
            data: unsafe { std::slice::from_raw_parts(img_data, size) }.to_vec(),
            tex_index: 0,                // will be set later
            sg_img: sg::Image { id: 0 }, // this too
            atlas_uvs: Vec4 {
                // and this
                x: 0.0,
                y: 0.0,
                z: 0.0,
                w: 0.0,
            },
        };

        ctx.core.sprites.insert(kind, sprite);

        // atlas time
        ctx.core.atlas.w = ATLAS_SIZE;
        ctx.core.atlas.h = ATLAS_SIZE;

        let mut stbrp_ctx = stbrp::stbrp_context {
            ..Default::default()
        };

        let mut nodes: [stbrp::stbrp_node; ATLAS_SIZE as usize] = [stbrp::stbrp_node {
            ..Default::default()
        }; ATLAS_SIZE as usize];

        // disgusting
        unsafe {
            stbrp::stbrp_init_target(
                &mut stbrp_ctx as *mut stbrp::stbrp_context,
                ctx.core.atlas.w as i32,
                ctx.core.atlas.h as i32,
                &mut nodes[0] as *mut stbrp::stbrp_node,
                ATLAS_SIZE as i32,
            )
        }

        let mut rects: Vec<stbrp::stbrp_rect> = Vec::new();

        for (id, img) in ctx.core.sprites.iter() {
            if (img.width == 0) {
                continue;
            }

            rects.push(stbrp::stbrp_rect {
                id: *id as i32,
                w: img.width,
                h: img.height,
                ..Default::default()
            });
        }

        let mut succ: i32;
        unsafe {
            succ = stbrp::stbrp_pack_rects(
                &mut stbrp_ctx as *mut stbrp::stbrp_context,
                &mut rects[0] as *mut stbrp::stbrp_rect,
                rects.len() as i32,
            );
        }

        if (succ == 0) {
            panic!("Failed to pack, too small of a suitcase?");
        }

        // mem alloc time
        let size = (ctx.core.atlas.w * ctx.core.atlas.h * 4) as usize;
        let mut data: Box<[u8]> = vec![0u8; size].into_boxed_slice();

        // copy rect row by row into atlas
        for rect in rects {
            let img = ctx
                .core
                .sprites
                .get_mut(&SpriteKind::from_repr(rect.id).unwrap())
                .unwrap();

            let rect_w = rect.w - 2;
            let rect_h = rect.h - 2;
            let src_row_stride = (rect.w * 4) as usize;
            let dest_col_offset = (rect.x + 1) * 4;
            let atlas_row_stride = ctx.core.atlas.w * 4;

            for row in 0..rect_h {
                let src_row_start = row as usize * src_row_stride;
                let dest_row_start =
                    (((rect.y + 1 + row) * ctx.core.atlas.w as i32 + (rect.x + 1)) * 4) as usize;

                let src_slice = &img.data[src_row_start..src_row_start + src_row_stride];
                let dest_slice = &mut data[dest_row_start..dest_row_start + src_row_stride];

                dest_slice.copy_from_slice(src_slice);
            }

            // bye bye old data
            let old_data = std::mem::take(&mut img.data);
            unsafe { stbi::stbi_image_free(old_data.as_ptr() as *mut std::ffi::c_void) }
            std::mem::forget(old_data);

            img.data = Vec::new();

            img.atlas_uvs.x = (rect.x as f32 + 1.0) / (ctx.core.atlas.w as f32);
            img.atlas_uvs.y = (rect.y as f32 + 1.0) / (ctx.core.atlas.h as f32);
            img.atlas_uvs.z = img.atlas_uvs.x + img.width as f32 / ctx.core.atlas.w as f32;
            img.atlas_uvs.w = img.atlas_uvs.y + img.height as f32 / ctx.core.atlas.h as f32;
        }

        /* pizza
        let img_buf =
            ImageBuffer::<Rgba<u8>, _>::from_raw(ATLAS_SIZE, ATLAS_SIZE, data.clone()).unwrap();
        img_buf.save("atlas.png").unwrap();*/

        let mut mip_levels = [sg::Range::new(); 16];
        mip_levels[0] = sg::Range {
            ptr: data.as_ptr() as *const std::ffi::c_void,
            size: data.len(),
        };

        let desc = sg::ImageDesc {
            width: ctx.core.atlas.w as i32,
            height: ctx.core.atlas.h as i32,
            pixel_format: sg::PixelFormat::Rgba8,
            data: sg::ImageData {
                mip_levels: mip_levels,
            },
            ..Default::default()
        };

        ctx.core.atlas.sg_image = sg::make_image(&desc);
        if (ctx.core.atlas.sg_image.id == sg::INVALID_ID) {
            panic!("Failed to create atlas image!");
        }

        ctx.core.atlas.sg_view = sg::make_view(&sg::ViewDesc {
            texture: sg::TextureViewDesc {
                image: ctx.core.atlas.sg_image,
                ..Default::default()
            },
            ..Default::default()
        });
    }

    Ok(())
}

const FONT_BITMAP_W: u32 = 1024;
const FONT_BITMAP_H: u32 = 1024;
const FONT_CHAR_COUNT: u32 = 96;
const FONT_HEIGHT: f32 = 120.0;

#[derive(Copy, Clone)]
#[repr(C)]
pub struct BakedChar {
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    pub xoff: f32,
    pub yoff: f32,
    pub xadvance: f32,
}

#[derive(Clone)]
pub struct Font {
    pub char_data: [BakedChar; FONT_CHAR_COUNT as usize],
    pub sg_image: sg::Image,
    pub sg_view: sg::View,
}

fn load_font(ctx: &mut Context) {
    let mut data: Box<[u8]> =
        vec![0u8; (FONT_BITMAP_W * FONT_BITMAP_H) as usize].into_boxed_slice();
    let font_data = include_bytes!("../beans/fonts/TitilliumWeb-Regular.ttf");
    let font = RFont::try_from_bytes(font_data as &[u8]).expect("Failed to build font!");
    let scale = Scale::uniform(FONT_HEIGHT);
    let v_metrics = font.v_metrics(scale);
    let line_height = (v_metrics.ascent - v_metrics.descent).ceil() as u32;

    let mut char_data = [BakedChar {
        x0: 0.0,
        y0: 0.0,
        x1: 0.0,
        y1: 0.0,
        xoff: 0.0,
        yoff: 0.0,
        xadvance: 0.0,
    }; FONT_CHAR_COUNT as usize];

    let mut x = 0u32;
    let mut y = 0u32;

    for (i, c) in (32u8..(32 + FONT_CHAR_COUNT as u8)).enumerate() {
        let glyph = font.glyph(char::from(c)).scaled(scale);
        let h_metrics = glyph.h_metrics();

        if let Some(bb) = glyph.exact_bounding_box() {
            let w = (bb.max.x - bb.min.x).ceil() as u32 + 1;
            let h = (bb.max.y - bb.min.y).ceil() as u32 + 1;

            if x + w >= FONT_BITMAP_W {
                x = 0;
                y += line_height;
            }

            assert!(y + h < FONT_BITMAP_H, "Not enough space in font bitmap");

            let positioned = glyph.positioned(point(x as f32 - bb.min.x, y as f32 - bb.min.y));
            positioned.draw(|px, py, v| {
                let px = x + px;
                let py = y + py;
                if px < FONT_BITMAP_W && py < FONT_BITMAP_H {
                    data[(py * FONT_BITMAP_W + px) as usize] = (v * 255.0) as u8;
                }
            });

            char_data[i] = BakedChar {
                x0: x as f32,
                y0: y as f32,
                x1: (x + w) as f32,
                y1: (y + h) as f32,
                xoff: bb.min.x,
                yoff: -bb.max.y, // Flip Y to match stb_truetype convention
                xadvance: h_metrics.advance_width,
            };

            x += w;
        } else {
            // Space or empty glyph
            char_data[i] = BakedChar {
                x0: 0.0,
                y0: 0.0,
                x1: 0.0,
                y1: 0.0,
                xoff: 0.0,
                yoff: 0.0,
                xadvance: h_metrics.advance_width,
            };
        }
    }

    /* pizza
    image::save_buffer(
        "font.png",
        &data,
        FONT_BITMAP_W,
        FONT_BITMAP_H,
        image::ColorType::L8,
    )
    .unwrap();*/

    let mut mip_levels = [sg::Range::new(); 16];
    mip_levels[0] = sg::Range {
        ptr: data.as_ptr() as *const std::ffi::c_void,
        size: data.len(),
    };

    let desc = sg::ImageDesc {
        width: FONT_BITMAP_W as i32,
        height: FONT_BITMAP_H as i32,
        pixel_format: sg::PixelFormat::R8,
        data: sg::ImageData {
            mip_levels: mip_levels,
        },
        ..Default::default()
    };

    let sg_img = sg::make_image(&desc);
    if (sg_img.id == sg::INVALID_ID) {
        panic!("Failed to create font image!");
    }

    let sg_view = sg::make_view(&sg::ViewDesc {
        texture: sg::TextureViewDesc {
            image: sg_img,
            ..Default::default()
        },
        ..Default::default()
    });

    ctx.core.font = Font {
        char_data: char_data,
        sg_image: sg_img,
        sg_view: sg_view,
    }
}
