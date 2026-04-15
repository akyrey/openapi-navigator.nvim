<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

class UserController extends Controller
{
    public function index()
    {
        return response()->json(['users' => []]);
    }

    public function store(Request $request)
    {
        return response()->json(['user' => $request->all()], 201);
    }

    public function show($id)
    {
        return response()->json(['user' => null]);
    }

    public function update(Request $request, $user)
    {
        return response()->json(['user' => null]);
    }

    public function destroy($user)
    {
        return response()->json(null, 204);
    }
}
