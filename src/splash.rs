use bevy::{asset::StrongHandle, prelude::*};

use super::GameState;

pub fn splash_plugin(app: &mut App) {
    app.add_systems(OnEnter(GameState::Splash), splash_setup)
        .add_systems(Update, countdown.run_if(in_state(GameState::Splash)));
}

#[derive(Component)]
struct OnSplashScreen;

#[derive(Resource, Deref, DerefMut)]
struct SplashTimer(Timer);

fn splash_setup(mut cmds: Commands, asset_server: Res<AssetServer>) {
    let icon: Handle<Image> = asset_server.load("images/splash.png");

    cmds.spawn((
        DespawnOnExit(GameState::Splash),
        Node {
            align_items: AlignItems::Center,
            justify_content: JustifyContent::Center,
            width: percent(100),
            height: percent(100),
            ..Default::default()
        },
        OnSplashScreen,
        children![(
            ImageNode::new(icon),
            Node {
                width: Val::Px(400.0),
                ..default()
            },
        )],
    ));

    cmds.insert_resource(SplashTimer(Timer::from_seconds(1.0, TimerMode::Once)));
}

fn countdown(
    mut gs: ResMut<NextState<GameState>>,
    time: Res<Time>,
    mut timer: ResMut<SplashTimer>,
) {
    if timer.tick(time.delta()).is_finished() {
        gs.set(GameState::Game);
    }
}
