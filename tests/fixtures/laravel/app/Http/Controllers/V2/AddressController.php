<?php

namespace App\Http\Controllers\V2;

use Illuminate\Http\Request;

class AddressController extends Controller
{
    public function show($userId, $addressId)
    {
        return response()->json(['address' => null]);
    }
}
