from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("main_app", "0008_delete_carousel2"),
    ]

    operations = [
        migrations.RenameField(
            model_name="carousel",
            old_name="descriptiom",
            new_name="description",
        ),
        migrations.RenameField(
            model_name="department",
            old_name="descriptiom",
            new_name="description",
        ),
        migrations.AlterField(
            model_name="carousel",
            name="carousel_slider",
            field=models.ImageField(upload_to="carousel/"),
        ),
        migrations.AlterField(
            model_name="carousel",
            name="description",
            field=models.TextField(blank=True),
        ),
        migrations.AddField(
            model_name="carousel",
            name="display_order",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="carousel",
            name="is_active",
            field=models.BooleanField(default=True),
        ),
        migrations.AlterField(
            model_name="department",
            name="carousel_slider",
            field=models.ImageField(upload_to="departments/"),
        ),
        migrations.AlterField(
            model_name="department",
            name="description",
            field=models.TextField(blank=True),
        ),
        migrations.AlterModelOptions(
            name="carousel",
            options={"ordering": ("display_order", "id")},
        ),
    ]
