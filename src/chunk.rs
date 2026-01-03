use crate::player::Player;

use super::GameState;
use bevy::{
    platform::collections::HashMap,
    prelude::*,
    sprite_render::{AlphaMode2d, TileData, TilemapChunk, TilemapChunkTileData},
};

pub struct ChunkManagerPlugin;

impl Plugin for ChunkManagerPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(OnEnter(GameState::Game), create_manager)
            .add_systems(Update, update_chunks.run_if(in_state(GameState::Game)));
    }
}

#[derive(Resource)]
pub struct ChunkManager {
    chunks: HashMap<ChunkPos, Entity>,
}

#[derive(Bundle)]
pub struct ChunkBundle {
    pub pos: ChunkPos,
    pub transform: Transform,
    pub tilemap_chunk: TilemapChunkEntity,
}

#[derive(Component)]
pub struct TilemapChunkEntity(Entity);

#[derive(Component, Hash, Eq, PartialEq, Debug, Clone, Copy)]
pub struct ChunkPos {
    x: i32,
    y: i32,
}

fn create_manager(mut cmds: Commands) {
    cmds.insert_resource(ChunkManager {
        chunks: HashMap::new(),
    });
}

fn update_chunks(
    mut cmds: Commands,
    mut query: Query<&mut Transform, With<Player>>,
    mut chunk_man: ResMut<ChunkManager>,
    asset_server: Res<AssetServer>,
) {
    for (t) in &mut query {
        let player_pos = t.translation;

        let player_chunk_pos = player_pos.div_euclid(Vec3::splat(320.0));

        let chunk_size = UVec2::splat(32);
        let tile_display_size = UVec2::splat(10);
        let tile_data: Vec<Option<TileData>> = (0..chunk_size.element_product())
            .map(|_| Some(TileData::from_tileset_index(0)))
            .collect();

        for x in -2..2 {
            for y in -2..2 {
                let offset = Vec2::new(x as f32, y as f32);
                let chunkpos = ChunkPos {
                    x: player_chunk_pos.x as i32 + x,
                    y: player_chunk_pos.y as i32 + y,
                };

                if !chunk_man.chunks.contains_key(&chunkpos) {
                    let tilemap_chunk = cmds
                        .spawn((
                            TilemapChunk {
                                chunk_size,
                                tile_display_size,
                                tileset: asset_server.load("images/empty_floor.png"),
                                alpha_mode: AlphaMode2d::Opaque,
                            },
                            TilemapChunkTileData(tile_data.clone()),
                        ))
                        .id();

                    let e = cmds
                        .spawn(ChunkBundle {
                            pos: chunkpos,
                            transform: Transform::from_xyz(
                                (chunkpos.x * 320) as f32,
                                (chunkpos.y * 320) as f32,
                                0.0,
                            ),
                            tilemap_chunk: TilemapChunkEntity(tilemap_chunk),
                        })
                        .id();
                }
            }
        }
    }
}
