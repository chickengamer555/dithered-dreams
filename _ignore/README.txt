If I did this correctly this should be the only file in this folder :)
Otherwise I have some work to do lol

I'm going to be doing much of my work in this directory while it is still a work in progress to ensure nothing I work on accidentally makes it's way into a commit or actual build before it's ready
You likely noticed I added a .gitignore file, that's to help ignore this folder but also to ignore other folders that apparently aren't essential to upload to git. Dunno how well it'll work but it's surely worth a try

And finally I would recommend you keep and utilise this folder aswell and create a builds/ folder insde of this one. It'll help keep exported builds attached to the project directory while making them possible to exclude as part of future builds
Which brings me to my last point being that you should go into the export menu and in your export presets add "_ignore/" to resources > Filters to exclude [...] from projects. This will allow for easier exclusion of WIP files from finished builds
