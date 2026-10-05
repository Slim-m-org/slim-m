# App Store listing and review

The text and answers used for the App Store Connect record of slim-m, so the next update starts from what was already said.
Nothing secret is in here: the review accounts are in `~/.secrets/slim-m/appreview.json` on the machine that set them up.

## Decisions

- The name stays `slim-m`.
- iPhone only.
- No EU trader status.
- Not distributed in France, which is what keeps export compliance at "no documentation required" (see below).
- Release is manual, so an approved build waits until it is released by hand.
- The review runs against a separate demo server, never the real community.

## Listing text

Name: `slim-m`

Subtitle: `Self-hosted private messaging`

Categories: Social Networking, then Productivity.

Keywords: `self-hosted,messaging app,space,private,chat,voice,community,server,screen share,canvas,group`

Promotional text:

> It's a messaging app where each space runs on its own server, so you pick who hosts your messages. Text channels, voice, screen sharing and a shared canvas, pretty much.

Description:

> slim-m is a messaging app where every community, called a space, runs on its own server.
>
> You pretty much get the server from whoever runs the space. They give you an address and an invite code, you put both into the app, and you're in. The first person to log in on a brand new server becomes its admin.
>
> What's in it:
> - Text channels with replies, threads, reactions, polls, code blocks, gifs and image attachments.
> - Voice channels, with screen sharing from your phone.
> - A shared canvas you can draw and put notes on while you're in a call.
> - Direct messages, mentions, and notifications you can turn down or off.
> - Roles and permissions, plus reporting and blocking, so whoever runs a space can moderate it.
> - Bots and a few small modules that run inside a space.
>
> About your data:
> The app talks to the server you pick. The default one is run by one person, and if you join a different space, whoever runs that space runs that server. There's no ad network, no analytics and no tracking in the app, and the push relay doesn't keep your messages. The app keeps a local copy of your messages on your phone, encrypted, and you can turn on Face ID to open it. You can delete your account from Settings, which purges your profile and sign-ins and leaves your old messages without your name on them.
>
> The source is available under a noncommercial license, so you can run your own server for free. It's a hobby project and probably has rough edges, which is why updates come out pretty often.

Support URL: `https://slim.npc-server.top/support`

Privacy policy URL: `https://slim.npc-server.top/privacy`

Copyright: `2026 NC1107`, the same holder as the license.

## App Privacy answers

Everything below is linked to the user, not used for tracking, and used only for app functionality.
The default server is run by the developer, so these count as collected.

| Data type | Why |
| --- | --- |
| Name | The display name. |
| User ID | The account id. |
| Device ID | The push token and the install id. |
| Other user content | Messages, polls, reactions. |
| Photos or videos | Attachments the user sends. |

Call audio is left out on purpose: it passes through the voice server in real time and isn't kept, which Apple doesn't count as collected.
No analytics, no crash reporting service, no advertising data, no location.
The location usage string exists only because an image picker links Core Location.

## Export compliance

The app uses standard encryption beyond what iOS provides: a SQLite cipher for the local database, the Dart `cryptography` package for sealed push previews, and WebRTC's DTLS-SRTP.
Apple's questions in App Store Connect (App Information, App Encryption Documentation) end in "you don't need to upload any documents" when the answers are standard algorithms and not available in France.
So the app stays out of France, and `ITSAppUsesNonExemptEncryption` stays `false` in `Info.plist`.
Whether the US export rules need anything further is the owner's call, since Apple says it's the developer's responsibility to review them.

## App Review notes

> slim-m connects to a server the user picks, so for review please use the demo server below and not the app's default one.
>
> To sign in: on the sign-in screen, change the Server field to `https://slim-review.npc-server.top`, then sign in with the username and password in the fields above. No invite code is needed.
>
> The demo server has a text channel called general with a few messages from two demo members, Riley and Morgan, a voice channel, and two more text channels.
>
> Report and block: press and hold a message from Riley or Morgan and choose Report message or Block user. You can also open a member's profile and choose Report user.
>
> Voice: tap the voice channel to join. iOS asks for the microphone. You'll be alone in it. Screen sharing starts from the call controls and uses a ReplayKit broadcast extension.
>
> Canvas: in a call, the canvas button opens a shared drawing board.
>
> Account deletion: Settings, then Account & devices, then Delete account. It's permanent. If you delete the account above, a spare one is `appreview2`, with its password on the last line of these notes.
>
> User-generated content: there's no anonymous sign-up, since every account needs an invite from a space's admins. Every message has Report message and every profile has Report user and Block user. Reports go to the space's admins, who can delete messages, time members out, or remove them, and admin actions are written to an audit log. Admins can also turn on rules for listed words, links, message floods and mention spam through an optional automod bot, and every rule is off until an admin turns it on. The developer can be reached through https://github.com/Slim-m-org/slim-m/issues.
>
> Permissions: the camera is for video in calls, the microphone for voice, the photo library for attaching and saving images, Face ID for the optional app lock, and local network because a space can run on a server on the user's own network. The audio background mode keeps a call going after the app is left.
>
> Push notifications are turned off on the demo server, so none will arrive there.
>
> Spare account: username `appreview2`, password given in App Store Connect only.

## The pages

`deploy/site/` holds the privacy policy and support pages, and an nginx config for them.
They are copied by hand to `site/` next to the compose file on the host, with the pages under `site/html/`.
A small nginx container serves them at `/privacy` and `/support` on the main host, behind Traefik.

```yaml
  slimm-site:
    image: nginx:1.27-alpine
    container_name: slim-m-site
    restart: unless-stopped
    networks:
      - traefik_proxy
    volumes:
      - ./site/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./site/html:/usr/share/nginx/html:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.slimm-site.rule=Host(`slim.${DOMAIN:-npc-server.top}`) && (PathPrefix(`/privacy`) || PathPrefix(`/support`))"
      - "traefik.http.routers.slimm-site.entrypoints=websecure"
      - "traefik.http.routers.slimm-site.tls.certresolver=cloudflare"
      - "traefik.http.services.slimm-site.loadbalancer.server.port=8080"
      - "traefik.docker.network=traefik_proxy"
```

## The review server

A second server container, `slim-m-review`, runs next to the real one at `https://slim-review.npc-server.top`.
It has its own volume, shares the LiveKit server for voice, and has push, gif search and link previews turned off.
It has no Watchtower label, so it stays on the version it was started with until it is recreated by hand.
The first account registered on it became its admin, and the reviewer and demo accounts were made through invites.
To reset it, stop the container, remove the `slimm_review_data` volume, start it again and register the admin first.

## Before pressing submit

1. A build is attached to version 1.0.
2. Screenshots are uploaded.
3. The age rating and content rights are answered.
4. App Privacy is published.
5. The review contact phone and email are filled in.
6. France is removed from availability.
7. The review server is up and the reviewer account signs in.
