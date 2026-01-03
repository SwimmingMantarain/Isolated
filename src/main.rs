#![allow(unused)] // Shut up!
#![allow(nonstandard_style)] // I don't care!!!!

use bevy::window::{MonitorSelection, PrimaryWindow, VideoModeSelection, Window, WindowMode};
use bevy::{input::keyboard::Key, prelude::*};

mod chunk;
mod player;
mod splash;

/// Enum that will be used as a global state for the game
#[derive(Clone, Copy, Default, Eq, PartialEq, Debug, Hash, States)]
enum GameState {
    #[default]
    Splash,
    Game,
}

fn main() {
    App::new()
        .add_plugins((
            DefaultPlugins.set(ImagePlugin::default_nearest()),
            player::PlayerPlugin,
            chunk::ChunkManagerPlugin,
        ))
        .init_state::<GameState>()
        .add_systems(Startup, setup)
        .add_systems(Update, kb_sys)
        .insert_resource(ClearColor(Color::linear_rgb(0.0, 0.0, 0.0)))
        .add_plugins(splash::splash_plugin)
        .run();
}

fn setup(mut cmds: Commands) {
    cmds.spawn(Camera2d);
}

fn kb_sys(
    kb_in: Res<ButtonInput<KeyCode>>,
    mut query: Query<&mut Window, With<PrimaryWindow>>,
    mut exit: MessageWriter<AppExit>,
) {
    // toggle fullscreen
    if kb_in.pressed(KeyCode::AltLeft) && kb_in.just_pressed(KeyCode::Enter) {
        if let Ok(mut window) = query.single_mut() {
            window.mode = match window.mode {
                WindowMode::Windowed => WindowMode::BorderlessFullscreen(MonitorSelection::Current),
                _ => WindowMode::Windowed,
            };
        }
    }

    // exit app
    if kb_in.just_pressed(KeyCode::Escape) {
        exit.write(AppExit::Success);
    }
}
