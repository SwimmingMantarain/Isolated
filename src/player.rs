use super::GameState;
use bevy::prelude::*;

/// Player functionality
pub struct PlayerPlugin;

impl Plugin for PlayerPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(OnEnter(GameState::Game), spawn_player)
            .add_systems(
                Update,
                (move_player, update_camera)
                    .chain()
                    .run_if(in_state(GameState::Game)),
            );
    }
}

#[derive(Bundle)]
pub struct PlayerBundle {
    player: Player,
    sprite: Sprite,
    transform: Transform,
    speed: Speed,
}

/// Used to extract player data in systems using ```With<Player>```
#[derive(Component)]
pub struct Player;

#[derive(Component)]
pub struct Speed(pub f32);

fn spawn_player(mut cmds: Commands, asset_server: Res<AssetServer>) {
    cmds.spawn(PlayerBundle {
        player: Player {},
        sprite: Sprite::from_image(asset_server.load("images/player.png")),
        transform: Transform::from_xyz(0.0, 69.0, 1.0),
        speed: Speed(250.0),
    });
}

const CAM_DECAY_RATE: f32 = 5.0;

fn update_camera(
    mut cam: Single<&mut Transform, (With<Camera2d>, Without<Player>)>,
    player: Single<&Transform, (With<Player>, Without<Camera2d>)>,
    time: Res<Time>,
) {
    let Vec3 { x, y, .. } = player.translation;
    let dir = Vec3::new(x, y, cam.translation.z);

    cam.translation
        .smooth_nudge(&dir, CAM_DECAY_RATE, time.delta_secs());
}

fn move_player(
    kb_in: Res<ButtonInput<KeyCode>>,
    mut query: Query<(&mut Transform, &mut Speed), With<Player>>,
    time: Res<Time>,
) {
    for (mut t, s) in &mut query {
        let mut dir = Vec3::ZERO;

        if kb_in.pressed(KeyCode::KeyW) {
            dir.y += 1.0;
        }

        if kb_in.pressed(KeyCode::KeyS) {
            dir.y -= 1.0;
        }

        if kb_in.pressed(KeyCode::KeyD) {
            dir.x += 1.0;
        }

        if kb_in.pressed(KeyCode::KeyA) {
            dir.x -= 1.0;
        }

        if dir.length() > 0.0 {
            dir = dir.normalize();
        }

        t.translation += dir * s.0 * time.delta_secs();
    }
}
