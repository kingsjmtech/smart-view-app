<?php

namespace Database\Seeders;

use App\Models\User;
use Illuminate\Database\Seeder;
use Illuminate\Support\Str;

class UsersSeeder extends Seeder
{
    public function run(): void
    {
        $users = [
            [
                'name' => 'Admin',
                'email' => 'admin@admin.com',
                'timezone' => 'Africa/Johannesburg',
                'email_verified_at' => now(),
                'password' => bcrypt('password'),
                'remember_token' => '',
                'status' => 'Active',
            ],
        ];

        if (config('app.env') === 'production' || config('app.env') === 'development') {
            $users[0]['password'] = bcrypt(Str::random());
        }

        foreach ($users as $user) {
            User::query()
                ->firstOrCreate(
                    ['email' => $user['email']],
                    $user
                );
        }

        if (config('app.env') === 'local') {
            User::factory()
                ->count(10)
                ->create();
        }
    }
}
